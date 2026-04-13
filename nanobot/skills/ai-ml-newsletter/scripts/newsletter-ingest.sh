#!/usr/bin/env bash
# Poll Hostinger IMAP for AI/ML newsletters (sender-filtered; shared inbox with dividend-intel).
#
# Credentials: ~/.wrenvps/ai-ml-newsletter/email_creds.json
# Idempotency: ~/.wrenvps/ai-ml-newsletter/processed_ids.json
#
# Cron: 45 6 * * * (America/New_York) — daily 6:45 AM ET
#
# Cache: <skill>/cache/raw/{slug}_{date}.json (override with AI_ML_NEWSLETTER_CACHE_RAW)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export AI_ML_NEWSLETTER_SKILL_ROOT="${AI_ML_NEWSLETTER_SKILL_ROOT:-$SKILL_ROOT}"

python3 << 'EOF'
import imaplib
import email
import email.header
import html.parser
import json
import os
import re
import sys
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from email.utils import parseaddr, parsedate_to_datetime
from urllib.parse import urlparse

SKILL_ROOT = os.environ.get("AI_ML_NEWSLETTER_SKILL_ROOT", "")
CREDS_PATH = os.path.expanduser("~/.wrenvps/ai-ml-newsletter/email_creds.json")
PROCESSED_PATH = os.path.expanduser("~/.wrenvps/ai-ml-newsletter/processed_ids.json")
CACHE_RAW = os.environ.get(
    "AI_ML_NEWSLETTER_CACHE_RAW",
    os.path.join(SKILL_ROOT, "cache", "raw") if SKILL_ROOT else os.path.expanduser("~/.wrenvps/ai-ml-newsletter/cache/raw"),
)

AI_ML_SENDERS = frozenset(
    s.lower()
    for s in [
        "theneuron@newsletter.theneurondaily.com",
        "swyx@ainews.email",
    ]
)

BLOCKED_SENDERS = frozenset(
    s.lower()
    for s in [
        "stockanalysis",
        "marketwatch",
        "seekingalpha",
        "morningbrew",
    ]
)

SUBJECT_AI_KEYWORDS = re.compile(
    r"\b(ai|ml|machine learning|artificial intelligence|gpt|llm|neural|deep learning)\b",
    re.IGNORECASE,
)

DIVIDEND_ONLY_HINT = re.compile(
    r"dividend|ex[-\s]?div|distribution|payout\s+ratio|dividend\s+yield|income\s+investor|"
    r"qualified\s+dividend|ex-dividend",
    re.IGNORECASE,
)

_URL_RE = re.compile(r"https?://[^\s\>\)\"\'\,\]]+")

_TRACK_HOSTS_NEWSLETTER = ("theneuron", "beehiiv", "substack", "newsletter")

_substack_redirect_cache: dict[str, str] = {}


def resolve_substack_redirect(url: str, timeout: int = 5) -> str:
    """Follow Substack redirect URLs to get the final destination."""
    if "substack.com/redirect" not in url:
        return url
    if url in _substack_redirect_cache:
        return _substack_redirect_cache[url]
    try:
        req = urllib.request.Request(
            url,
            method="HEAD",
            headers={"User-Agent": "Mozilla/5.0"},
        )
        resp = urllib.request.urlopen(req, timeout=timeout)
        resolved = resp.url or url
    except Exception:
        resolved = url
    _substack_redirect_cache[url] = resolved
    return resolved

# ── Credentials ──────────────────────────────────────────────────────────────
IMAP_HOST = ""
IMAP_PORT = 993
IMAP_USER = ""
IMAP_PASS = ""
IMAP_SSL = True


def _load_imap_creds() -> None:
    global IMAP_HOST, IMAP_PORT, IMAP_USER, IMAP_PASS, IMAP_SSL
    try:
        with open(CREDS_PATH, encoding="utf-8") as f:
            creds = json.load(f)
        IMAP_HOST = creds["host"]
        IMAP_PORT = int(creds.get("port", 993))
        IMAP_USER = creds["username"]
        IMAP_PASS = creds["password"]
        IMAP_SSL = bool(creds.get("ssl", True))
    except FileNotFoundError:
        print(f"ERROR: credentials not found at {CREDS_PATH}", file=sys.stderr)
        sys.exit(1)
    except (KeyError, json.JSONDecodeError) as e:
        print(f"ERROR: bad credentials file: {e}", file=sys.stderr)
        sys.exit(1)


class _HTMLStripper(html.parser.HTMLParser):
    def __init__(self):
        super().__init__()
        self._parts = []

    def handle_data(self, data):
        self._parts.append(data)

    def get_text(self):
        return " ".join(self._parts)


def strip_html(html_text: str) -> str:
    stripper = _HTMLStripper()
    try:
        stripper.feed(html_text)
    except Exception:
        pass
    return stripper.get_text()


def get_body_and_html(msg) -> tuple[str, str | None]:
    plain = None
    html_body = None
    if msg.is_multipart():
        for part in msg.walk():
            ct = part.get_content_type()
            cd = part.get("Content-Disposition", "")
            if "attachment" in cd:
                continue
            if ct == "text/plain" and plain is None:
                try:
                    charset = part.get_content_charset() or "utf-8"
                    plain = part.get_payload(decode=True).decode(charset, errors="replace")
                except Exception:
                    pass
            elif ct == "text/html" and html_body is None:
                try:
                    charset = part.get_content_charset() or "utf-8"
                    html_body = part.get_payload(decode=True).decode(charset, errors="replace")
                except Exception:
                    pass
    else:
        ct = msg.get_content_type()
        try:
            charset = msg.get_content_charset() or "utf-8"
            raw = msg.get_payload(decode=True).decode(charset, errors="replace")
            if ct == "text/html":
                html_body = raw
            else:
                plain = raw
        except Exception:
            pass

    if plain:
        text = plain
    elif html_body:
        text = strip_html(html_body)
    else:
        text = ""
    return text, html_body


def decode_subject(raw_subject) -> str:
    parts = email.header.decode_header(raw_subject or "")
    decoded = []
    for part, charset in parts:
        if isinstance(part, bytes):
            decoded.append(part.decode(charset or "utf-8", errors="replace"))
        else:
            decoded.append(str(part))
    return " ".join(decoded)


def extract_urls(text: str) -> list[str]:
    found = _URL_RE.findall(text or "")
    normalized = [u.rstrip(").,;]") for u in found]
    substack_unique: list[str] = []
    seen_ss: set[str] = set()
    for u in normalized:
        if "substack.com/redirect" in u and u not in seen_ss:
            seen_ss.add(u)
            substack_unique.append(u)
    to_resolve = substack_unique[:15]
    resolved_map: dict[str, str] = {}
    if to_resolve:
        with ThreadPoolExecutor(max_workers=5) as ex:
            futures = {ex.submit(resolve_substack_redirect, u): u for u in to_resolve}
            for fut in as_completed(futures):
                orig = futures[fut]
                try:
                    resolved_map[orig] = fut.result()
                except Exception:
                    resolved_map[orig] = orig
    out: list[str] = []
    seen: set[str] = set()
    for u in normalized:
        if "substack.com/redirect" in u:
            u = resolved_map.get(u, u)
        if u not in seen:
            seen.add(u)
            out.append(u)
    return out


def link_type_for_url(url: str) -> str:
    host = (urlparse(url).netloc or "").lower()
    if any(h in host for h in _TRACK_HOSTS_NEWSLETTER):
        return "expanded_coverage"
    if any(
        x in host
        for x in (
            "openai.com",
            "anthropic.com",
            "google.com",
            "microsoft.com",
            "meta.com",
            "github.com",
            "arxiv.org",
            "nature.com",
            "reuters.com",
            "sec.gov",
        )
    ):
        return "primary_source"
    return "related"


def infer_categories(headline: str, summary: str) -> list[str]:
    blob = f"{headline} {summary}".lower()
    tags = []
    rules = [
        ("LLM", r"\b(llm|gpt|claude|gemini|language model|openai|anthropic)\b"),
        ("product_launch", r"\b(launch|releases|introduces|unveils|ships|beta)\b"),
        ("regulation", r"\b(regulation|regulator|eu ai act|congress|senate|ftc|sec\b|lawsuit)\b"),
        ("security", r"\b(cve|vulnerability|exploit|breach|ransomware|malware)\b"),
        ("research", r"\b(research|paper|arxiv|benchmark|study|breakthrough)\b"),
        ("dev_tools", r"\b(api|sdk|developer|cursor|copilot|vscode|github)\b"),
        ("geopolitics", r"\b(china|taiwan|sanction|export control|defense|military)\b"),
    ]
    for name, pat in rules:
        if re.search(pat, blob):
            tags.append(name)
    return sorted(set(tags))[:6]


def newsletter_label_from_sender(from_email: str) -> tuple[str, str]:
    low = from_email.lower()
    if "theneuron" in low:
        return "The Neuron", "the-neuron"
    dom = from_email.split("@")[-1] if "@" in from_email else "unknown"
    return dom.split(".")[0].replace("-", " ").title(), re.sub(r"[^a-z0-9]+", "-", low.split("@")[0].lower()).strip("-")


def parse_notable_apps_section(text: str) -> tuple[list[dict], str]:
    """Return (apps, remainder_without_section) for rough section isolation."""
    lines = text.splitlines()
    apps = []
    in_section = False
    kept: list[str] = []
    for line in lines:
        up = line.strip()
        if re.match(r"(?i)^#*\s*notable\s+apps", up) or re.match(
            r"(?i)^notable\s+apps\s+(&|and)\s+sites", up
        ) or re.match(r"(?i)^\*+\s*notable\s+apps", up):
            in_section = True
            continue
        if in_section:
            if up == "":
                continue
            if up.startswith("#") and not re.match(r"(?i)notable", up):
                in_section = False
                kept.append(line)
                continue
            if re.match(r"(?i)^top\s+stories", up) or re.match(r"(?i)^today[’']?s\s+", up):
                in_section = False
            if in_section:
                raw_urls = extract_urls(up)
                name_guess = re.sub(r"^[-*•]\s*", "", up)
                name_guess = _URL_RE.sub("", name_guess).strip(" -—\t")
                desc = ""
                if "—" in name_guess or " - " in name_guess:
                    parts = re.split(r"\s[—-]\s", name_guess, maxsplit=1)
                    if len(parts) == 2:
                        name_guess, desc = parts[0].strip(), parts[1].strip()
                cat = "tool"
                if re.search(r"(?i)\bcode|dev|api\b", name_guess + desc):
                    cat = "dev_tools"
                if raw_urls:
                    apps.append(
                        {
                            "name": (name_guess or "Link")[:120],
                            "url": raw_urls[0],
                            "description": desc[:400] if desc else name_guess[:400],
                            "category": cat,
                        }
                    )
                continue
        kept.append(line)
    return apps, "\n".join(kept)


def parse_stories_the_neuron_style(text: str) -> tuple[list[dict], list[dict]]:
    """Markdown H1–H3 sections, numbered lists, and/or paragraph blocks with URLs."""
    stories: list[dict] = []
    notable_apps, body = parse_notable_apps_section(text)

    # Markdown header stories (The Neuron uses # 😺 **Headline**)
    header_chunks = re.split(r"(?m)^(#{1,3}\s+.+)$", body)
    if len(header_chunks) >= 3:
        for i in range(1, len(header_chunks), 2):
            headline_raw = (
                header_chunks[i]
                .lstrip("#")
                .strip()
                .lstrip("😺🤖🔥💡🚀⚠️🎯📊🧠🤯💰🏆✨ ")
                .strip("*")
            )
            chunk = header_chunks[i + 1].strip() if i + 1 < len(header_chunks) else ""
            if len(headline_raw) < 3:
                continue
            urls = extract_urls(chunk)
            summary = re.sub(r"\s+", " ", chunk)[:800]
            headline_clean = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", headline_raw)
            links = [
                {"url": u, "context": summary[:200], "type": link_type_for_url(u)}
                for u in urls[:12]
            ]
            stories.append(
                {
                    "headline": headline_clean[:300],
                    "summary": summary or headline_clean,
                    "links": links,
                    "categories": infer_categories(headline_clean, summary),
                }
            )

    if not stories:
        for m in re.finditer(
            r"(?m)^\s*(\d+)\.\s+([^\n]+)\n([\s\S]*?)(?=^\s*\d+\.\s+|\Z)",
            body,
        ):
            headline = m.group(2).strip()
            chunk = m.group(3).strip()
            if len(headline) < 3:
                continue
            urls = extract_urls(chunk)
            if not urls and len(chunk) < 20:
                continue
            summary = re.sub(r"\s+", " ", chunk)[:800]
            links = []
            for u in urls[:12]:
                links.append({"url": u, "context": summary[:200], "type": link_type_for_url(u)})
            stories.append(
                {
                    "headline": headline[:300],
                    "summary": summary or headline,
                    "links": links,
                    "categories": infer_categories(headline, summary),
                }
            )

    if not stories:
        # Fallback: paragraph blocks with a URL and a short first line as headline
        blocks = re.split(r"\n{2,}", body)
        for blk in blocks:
            blk = blk.strip()
            if not blk or len(blk) < 40:
                continue
            urls = extract_urls(blk)
            if not urls:
                continue
            first = blk.split("\n", 1)[0].strip()
            first = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", first)
            if len(first) > 160:
                first = first[:157] + "..."
            rest = blk[len(first) :].strip() if len(blk) > len(first) else blk
            summary = re.sub(r"\s+", " ", rest)[:800]
            links = [
                {"url": u, "context": summary[:200], "type": link_type_for_url(u)}
                for u in urls[:12]
            ]
            stories.append(
                {
                    "headline": first,
                    "summary": summary or first,
                    "links": links,
                    "categories": infer_categories(first, summary),
                }
            )

    return stories, notable_apps


def build_record(
    newsletter_name: str,
    slug: str,
    date_str: str,
    message_id: str,
    body: str,
    from_email: str,
    subject: str,
    sender_review: bool,
) -> dict:
    stories, notable_apps = parse_stories_the_neuron_style(body)
    raw_links = extract_urls(body)
    return {
        "newsletter": newsletter_name,
        "date": date_str,
        "message_id": message_id,
        "subject": subject[:300],
        "from": from_email,
        "sender_review": sender_review,
        "stories": stories,
        "notable_apps_sites": notable_apps,
        "raw_links": raw_links[:500],
    }


def is_ai_ml_newsletter(from_email: str, subject: str, body: str) -> bool:
    fe = from_email.lower()
    if any(b in fe for b in BLOCKED_SENDERS):
        return False
    if fe in AI_ML_SENDERS:
        return True
    if SUBJECT_AI_KEYWORDS.search(subject or ""):
        return True
    combined = f"{subject} {body[:2000]}"
    if DIVIDEND_ONLY_HINT.search(combined) and not SUBJECT_AI_KEYWORDS.search(subject or ""):
        return False
    return False


def load_processed_ids() -> set[str]:
    try:
        with open(PROCESSED_PATH, encoding="utf-8") as f:
            return set(json.load(f))
    except (FileNotFoundError, json.JSONDecodeError, TypeError):
        return set()


def save_processed_ids(ids: set[str]) -> None:
    os.makedirs(os.path.dirname(PROCESSED_PATH), exist_ok=True)
    with open(PROCESSED_PATH, "w", encoding="utf-8") as f:
        json.dump(sorted(ids), f, indent=2)


def merge_raw_file(path: str, new_data: dict) -> None:
    if os.path.isfile(path):
        try:
            with open(path, encoding="utf-8") as f:
                old = json.load(f)
        except json.JSONDecodeError:
            old = {}
        if isinstance(old, dict) and "stories" in old:
            seen_h = {s.get("headline", "").lower() for s in old.get("stories", [])}
            for s in new_data.get("stories", []):
                if s.get("headline", "").lower() not in seen_h:
                    old.setdefault("stories", []).append(s)
                    seen_h.add(s.get("headline", "").lower())
            seen_a = {(a.get("url") or "").lower() for a in old.get("notable_apps_sites", [])}
            for a in new_data.get("notable_apps_sites", []):
                u = (a.get("url") or "").lower()
                if u and u not in seen_a:
                    old.setdefault("notable_apps_sites", []).append(a)
                    seen_a.add(u)
            old["raw_links"] = sorted(set(old.get("raw_links", []) + new_data.get("raw_links", [])))[:500]
            mids = list(old.get("message_ids", []))
            mid = new_data.get("message_id", "")
            if mid and mid not in mids:
                mids.append(mid)
            old["message_ids"] = mids
            with open(path, "w", encoding="utf-8") as f:
                json.dump(old, f, indent=2)
            return
    out = dict(new_data)
    out["message_ids"] = [new_data.get("message_id", "")]
    with open(path, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=2)


# ── Main ───────────────────────────────────────────────────────────────────────

def main() -> None:
    _load_imap_creds()
    processed_ids = load_processed_ids()
    errors: list[str] = []
    os.makedirs(CACHE_RAW, exist_ok=True)

    try:
        if IMAP_SSL:
            conn = imaplib.IMAP4_SSL(IMAP_HOST, IMAP_PORT)
        else:
            conn = imaplib.IMAP4(IMAP_HOST, IMAP_PORT)
        conn.login(IMAP_USER, IMAP_PASS)
        conn.select("INBOX")

        status, data = conn.search(None, "UNSEEN")
        if status != "OK":
            raise RuntimeError(f"IMAP SEARCH failed: {status}")

        msg_ids = data[0].split() if data[0] else []
        print(f"Found {len(msg_ids)} unread messages", flush=True)

        for msg_id_bytes in msg_ids:
            msg_id_str = msg_id_bytes.decode()
            try:
                status, msg_data = conn.fetch(msg_id_bytes, "(RFC822)")
                if status != "OK":
                    errors.append(f"msg {msg_id_str}: FETCH failed ({status})")
                    continue

                raw_email = None
                for item in msg_data:
                    if isinstance(item, tuple) and isinstance(item[1], bytes) and len(item[1]) > 200:
                        raw_email = item[1]
                        break
                if raw_email is None:
                    errors.append(f"msg {msg_id_str}: no RFC822 content")
                    continue

                msg = email.message_from_bytes(raw_email)
                message_id_header = msg.get("Message-ID", "").strip()
                unique_id = message_id_header if message_id_header else f"seq:{msg_id_str}"

                if unique_id in processed_ids:
                    conn.store(msg_id_bytes, "+FLAGS", "\\Seen")
                    continue

                subject = decode_subject(msg.get("Subject", ""))
                from_raw = msg.get("From", "")
                _, from_addr = parseaddr(from_raw)
                from_addr = from_addr or from_raw
                date_raw = msg.get("Date", "")
                try:
                    date_dt = parsedate_to_datetime(date_raw)
                    if date_dt.tzinfo is None:
                        date_dt = date_dt.replace(tzinfo=timezone.utc)
                    date_str = date_dt.strftime("%Y-%m-%d")
                except Exception:
                    date_str = datetime.now(tz=timezone.utc).strftime("%Y-%m-%d")

                body, _html = get_body_and_html(msg)

                if not is_ai_ml_newsletter(from_addr, subject, body):
                    print(f"  skip {msg_id_str} (not AI/ML newsletter filter): {subject[:50]}", flush=True)
                    continue

                sender_review = from_addr.lower() not in AI_ML_SENDERS and bool(
                    SUBJECT_AI_KEYWORDS.search(subject or "")
                )

                newsletter_name, slug = newsletter_label_from_sender(from_addr)
                rec = build_record(
                    newsletter_name,
                    slug,
                    date_str,
                    unique_id,
                    body,
                    from_addr,
                    subject,
                    sender_review,
                )

                out_path = os.path.join(CACHE_RAW, f"{slug}_{date_str}.json")
                merge_raw_file(out_path, rec)
                print(f"  wrote {out_path} ({len(rec['stories'])} stories)", flush=True)

                conn.store(msg_id_bytes, "+FLAGS", "\\Seen")
                processed_ids.add(unique_id)

            except Exception as e:
                errors.append(f"msg {msg_id_str}: {e}")
                print(f"  WARNING: msg {msg_id_str} skipped — {e}", file=sys.stderr, flush=True)

        conn.logout()

    except imaplib.IMAP4.error as e:
        print(f"ERROR: IMAP connection failed — {e}", file=sys.stderr)
        sys.exit(1)
    except OSError as e:
        print(f"ERROR: network error — {e}", file=sys.stderr)
        sys.exit(1)

    save_processed_ids(processed_ids)
    print(f"\nDone. Cache: {CACHE_RAW} | Errors: {len(errors)}")
    for e in errors:
        print(f"  {e}", file=sys.stderr)


if __name__ == "__main__":
    main()
EOF
