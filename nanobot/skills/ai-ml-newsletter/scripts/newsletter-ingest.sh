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

BODY_TEXT_DEBUG_LIMIT = 30000

AI_ML_SENDERS = frozenset(
    s.lower()
    for s in [
        "theneuron@newsletter.theneurondaily.com",
        # AINews (swyx) — Substack + legacy
        "swyx+ainews@substack.com",
        "swyx@ainews.email",
        "ainews@substack.com",
        # Interconnects (Nathan Lambert)
        "nathan@substack.com",
        "nwang0@substack.com",
        "hello@interconnects.ai",
        "nathan@interconnects.ai",
        "interconnects@substack.com",
        # TLDR AI
        "dan@tldr.tech",
        "dan@tldrnewsletter.com",
        "noreply@tldr.tech",
        "hello@tldr.tech",
        "tldr@tldrnewsletter.com",
        # Simplifying AI (Alvaro Cintas)
        "simplifyingai@newsletter.alvarocintas.com",
        "simplifying@substack.com",
        # Tess Research (Tessara)
        "hello@tessresearch.chainofthought.xyz",
        "hello@tessresearch.substack.com",
        "tessara@substack.com",
    ]
)

AI_ML_SENDER_DOMAINS = frozenset(
    s.lower()
    for s in [
        "substack.com",
        "tldrnewsletter.com",
        "newsletter.alvarocintas.com",
        "chainofthought.xyz",
        "theneurondaily.com",
    ]
)

AI_ML_DOMAIN_SUBJECT = re.compile(
    r"\b(ai|ml|llm|gpt|claude|gemini|openai|anthropic|neural|deep learning|"
    r"machine learning|artificial intelligence)\b",
    re.IGNORECASE,
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

# Organizational section titles (not stories) — exact + multi-word substring match.
SECTION_HEADER_BLOCKLIST = frozenset(
    {
        "stories that matter",
        "regime snapshot",
        "notable apps & sites",
        "notable apps and sites",
        "quick links",
        "today's top ai/ml news",
        "in today's newsletter",
        "what we're reading",
        "from our sponsors",
        "sponsor",
        "advertisement",
        "promoted",
        "top stories",
        "today's briefing",
        "reading list",
        # The Neuron sections / sponsor-ish
        "treats to try",
        "around the horn",
        "cat's commentary",
        "a cat's commentary",
        "intelligent insights",
        "ai skill of the day",
        "unlock access",
        "your product needs",
        "headlines & launches",
        "deep dives & analysis",
        "ai twitter recap",
        "ai reddit recap",
        "top tweets (by engagement)",
        "links:",
    }
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
    to_resolve = substack_unique[:80]
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


def clean_summary(text: str) -> str:
    """Remove common newsletter noise from story summaries."""
    t = text or ""
    t = re.sub(r"View image:\s*\S+", "", t)
    t = re.sub(r"Follow image link:\s*\S+", "", t, flags=re.IGNORECASE)
    t = re.sub(r"Follow image:\s*\S+", "", t, flags=re.IGNORECASE)
    t = re.sub(r"Click here to\s+[^.]+\.", "", t)
    t = re.sub(r"Read more\s*»?\s*$", "", t, flags=re.MULTILINE)
    t = re.sub(
        r"Share this\s+(post|article|newsletter)[^.]*\.",
        "",
        t,
        flags=re.IGNORECASE,
    )
    t = re.sub(r"Upgrade to paid[^.]*\.", "", t, flags=re.IGNORECASE)
    t = re.sub(r"\s+", " ", t).strip()
    return t


def _is_section_header_headline(headline: str) -> bool:
    h = re.sub(r"\s+", " ", (headline or "").lower().strip())
    h = h.strip("*# ")
    if h in SECTION_HEADER_BLOCKLIST:
        return True
    for block in SECTION_HEADER_BLOCKLIST:
        if " " in block and block in h:
            return True
    return False


def newsletter_label_from_sender(from_email: str) -> tuple[str, str]:
    low = from_email.lower()
    if "theneuron" in low:
        return "The Neuron", "the-neuron"
    if "ainews" in low or "swyx" in low.split("@")[0] or "+ainews" in low:
        return "AINews", "ainews"
    if "interconnects" in low or low in (
        "nathan@substack.com",
        "nwang0@substack.com",
    ):
        return "Interconnects", "interconnects"
    if "tldrnewsletter.com" in low or "tldr.tech" in low or "readtldr" in low:
        return "TLDR AI", "tldr-ai"
    if "alvarocintas" in low or "simplifyingai" in low or "simplifying" in low.split("@")[0]:
        return "Simplifying AI", "simplifying-ai"
    if "tessresearch" in low or "chainofthought.xyz" in low or "tessara" in low:
        return "Tess Research", "tess-research"
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


_SUBSTACK_PARA_SKIP = (
    "view this post",
    "unsubscribe",
    "upgrade to paid",
    "share this post",
)


def _substack_boilerplate_paragraph(para: str) -> bool:
    """AINews-style deck / date lines / long essay openers — not stories."""
    if re.search(r"(?i)\btop story\b", para):
        return False
    first = para.split("\n", 1)[0].strip()
    if re.match(r"(?i)^ai news for\b", first):
        return True
    if re.match(
        r"(?i)^(in |the |when |as |but |for |on |at |while |after |before )\b",
        first,
    ) and len(first) > 70:
        return True
    return False


def _substack_next_para_is_new_story(para: str) -> bool:
    """True if the next paragraph should start its own item (do not merge into prior)."""
    first = para.split("\n", 1)[0].strip()
    fl = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", first)
    fl = re.sub(r"^[#*\s]+", "", fl).strip()
    if not fl or _is_section_header_headline(fl):
        return False
    if re.search(r"(?i)\btop story\b", fl):
        return True
    if extract_urls(para) and len(fl) < 120 and len(fl.split()) <= 14 and not fl.lower().startswith(
        "http"
    ):
        return True
    return False


_TLDR_MIN_READ_HEADLINE = re.compile(
    r"\(\d+\s+MIN(?:UTE)?S?\s+READ\)",
    re.IGNORECASE,
)


def _substack_line_looks_like_headline(line: str) -> bool:
    """Short title-like line (AINews / dense Substack), not a prose sentence."""
    s = line.strip()
    if len(s) < 10 or len(s) >= 120:
        return False
    if s.startswith(("http", "[", "*")):
        return False
    if not s[:1].isupper():
        return False
    if s.endswith((".", "!", "?")):
        return False
    if len(s.split()) > 12:
        return False
    return True


def _parse_substack_line_by_line(body: str) -> list[dict]:
    """Substack digests with single newlines only (AINews): headline line + following prose."""
    stories: list[dict] = []
    lines = body.split("\n")
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        if not line:
            i += 1
            continue
        low = line.lower()
        if any(p in low for p in _SUBSTACK_PARA_SKIP):
            i += 1
            continue
        if _is_section_header_headline(line):
            i += 1
            continue
        if re.match(r"(?i)^ai news for\b", line):
            i += 1
            continue
        if re.match(
            r"(?i)^(in |the |when |as |but |for |on |at |while |after |before )\b",
            line,
        ) and len(line) > 90:
            i += 1
            continue

        is_headline = _substack_line_looks_like_headline(line)

        if is_headline:
            headline = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", line)
            headline = re.sub(r"^[#*\s]+", "", headline).strip()
            if len(headline) < 5 or _is_section_header_headline(headline):
                i += 1
                continue

            desc_lines: list[str] = []
            i += 1
            while i < len(lines):
                nxt = lines[i].strip()
                if not nxt:
                    i += 1
                    break
                next_is_headline = _substack_line_looks_like_headline(nxt)
                if next_is_headline:
                    break
                desc_lines.append(nxt)
                i += 1

            summary = clean_summary(" ".join(desc_lines)[:800])
            url_blob = line + " " + " ".join(desc_lines)
            urls = extract_urls(url_blob)
            if not urls:
                continue
            links = [
                {"url": u, "context": summary[:200], "type": link_type_for_url(u)}
                for u in urls[:12]
            ]
            stories.append(
                {
                    "headline": headline[:300],
                    "summary": summary or clean_summary(headline) or headline,
                    "links": links,
                    "categories": infer_categories(headline, summary),
                }
            )
        else:
            i += 1

    return stories


def _parse_substack_paragraph_stories(body: str) -> list[dict]:
    """AINews-style dense paragraphs without --- section breaks."""
    stories: list[dict] = []
    paragraphs = [p.strip() for p in body.split("\n\n") if p.strip()]
    if len(paragraphs) <= 2:
        return _parse_substack_line_by_line(body)

    i = 0
    while i < len(paragraphs):
        para = paragraphs[i]
        if len(para) < 20:
            i += 1
            continue
        para_lower = para.lower()
        if any(p in para_lower for p in _SUBSTACK_PARA_SKIP):
            i += 1
            continue
        if _substack_boilerplate_paragraph(para):
            i += 1
            continue

        lines = para.split("\n")
        first_line = lines[0].strip()
        first_line_clean = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", first_line)
        first_line_clean = re.sub(r"^[#*\s]+", "", first_line_clean).strip()
        flc_lower = first_line_clean.lower()

        if _is_section_header_headline(first_line_clean):
            i += 1
            continue

        is_headline = (
            len(first_line_clean) < 120
            and not flc_lower.startswith("http")
            and len(first_line_clean) > 5
            and (
                re.search(r"(?i)\btop story\b", first_line_clean)
                or ":" in first_line_clean[:110]
                or len(first_line_clean.split()) <= 14
            )
        )

        if is_headline:
            headline = first_line_clean
            rest = "\n".join(lines[1:]).strip()
            merge_next = (
                i + 1 < len(paragraphs)
                and len(rest) < 100
                and not _substack_next_para_is_new_story(paragraphs[i + 1])
            )
            if merge_next:
                url_blob = para + "\n\n" + paragraphs[i + 1]
                summary_text = clean_summary(
                    re.sub(r"\s+", " ", (rest + " " + paragraphs[i + 1]))[:800]
                )
                i += 2
            else:
                url_blob = para
                summary_text = clean_summary(re.sub(r"\s+", " ", rest)[:800])
                i += 1
        else:
            headline_raw = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", first_line)
            headline = re.sub(r"^[#*\s]+", "", headline_raw).strip()[:300]
            if len(headline) <= 5 or _is_section_header_headline(headline):
                i += 1
                continue
            url_blob = para
            summary_text = clean_summary(re.sub(r"\s+", " ", para)[:800])
            i += 1

        if _is_section_header_headline(headline):
            continue
        urls = extract_urls(url_blob)
        if not urls:
            continue
        links = [
            {"url": u, "context": summary_text[:200], "type": link_type_for_url(u)}
            for u in urls[:12]
        ]
        stories.append(
            {
                "headline": headline[:300],
                "summary": summary_text or clean_summary(headline) or headline,
                "links": links,
                "categories": infer_categories(headline, summary_text),
            }
        )
    return stories


def parse_substack_stories(text: str) -> tuple[list[dict], list[dict]]:
    """Parse Substack plain-text digests (AINews, Interconnects, Latent Space, etc.)."""
    stories: list[dict] = []
    notable_apps, body = parse_notable_apps_section(text)

    body = re.sub(
        r"(?i)^View this post on the web at[^\n]+\n*",
        "",
        body,
    )
    body = re.sub(r"\n*Unsubscribe\s+https://substack\.com.*$", "", body, flags=re.DOTALL)
    body = re.sub(r"\n*Upgrade to paid.*$", "", body, flags=re.DOTALL)

    sections = re.split(r"\n-{3,}\n", body)
    skip_head = (
        "view this post",
        "unsubscribe",
        "upgrade to paid",
        "share this post",
        "click here",
        "read more",
    )

    if len(sections) <= 1:
        blob = sections[0].strip() if sections else ""
        stories = _parse_substack_paragraph_stories(blob)
        return stories, notable_apps

    for section in sections:
        section = section.strip()
        if not section or len(section) < 40:
            continue

        header_match = re.search(r"(?m)^#{1,3}\s+(.+)$", section)
        if header_match:
            headline = header_match.group(1).strip().strip("*")
            chunk = section[header_match.end() :].strip()
        else:
            lines = section.split("\n", 1)
            headline = lines[0].strip()
            chunk = lines[1].strip() if len(lines) > 1 else ""

        headline = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", headline)
        headline = re.sub(r"^[#*\s]+", "", headline).strip()

        if len(headline) < 3:
            continue
        hl_low = headline.lower()
        if any(p in hl_low for p in skip_head):
            continue
        if _is_section_header_headline(headline):
            continue

        urls = extract_urls(chunk)
        summary = clean_summary(re.sub(r"\s+", " ", chunk)[:800])
        links = [
            {"url": u, "context": summary[:200], "type": link_type_for_url(u)}
            for u in urls[:12]
        ]
        stories.append(
            {
                "headline": headline[:300],
                "summary": summary or clean_summary(headline) or headline,
                "links": links,
                "categories": infer_categories(headline, summary),
            }
        )

    return stories, notable_apps


_TLDR_SECTION_START = re.compile(r"\n(?=🚀|💡|🔥|📊|⚡|🧠|🤖|🎯|🤝|💻)")


def parse_tldr_stories(text: str) -> tuple[list[dict], list[dict]]:
    """Parse TLDR AI-style emoji sections and bullet blocks."""
    stories: list[dict] = []
    notable_apps: list[dict] = []

    body = re.sub(
        r"^.*?(?=🚀|💡|🔥|📊|⚡|🧠|🤖|🎯|🤝|💻)",
        "",
        text,
        count=1,
        flags=re.DOTALL,
    )
    if body == text:
        body = text
    body = re.sub(r"\n*Quick Links.*$", "", body, flags=re.IGNORECASE | re.DOTALL)

    sections = _TLDR_SECTION_START.split(body)
    for section in sections:
        section = section.strip()
        if not section:
            continue
        raw_blocks = [b.strip() for b in re.split(r"\n{2,}", section)]
        merged_blocks: list[str] = []
        bi = 0
        while bi < len(raw_blocks):
            block = raw_blocks[bi]
            if not block or len(block) < 10:
                bi += 1
                continue
            is_tm = len(block) < 200 and bool(_TLDR_MIN_READ_HEADLINE.search(block))
            if is_tm and bi + 1 < len(raw_blocks):
                nxt = raw_blocks[bi + 1].strip()
                nxt_tm = (
                    nxt
                    and len(nxt) < 200
                    and bool(_TLDR_MIN_READ_HEADLINE.search(nxt))
                )
                if not nxt_tm:
                    merged_blocks.append(block + "\n" + nxt)
                    bi += 2
                    continue
            merged_blocks.append(block)
            bi += 1

        for block in merged_blocks:
            block = block.strip()
            if not block or len(block) < 30:
                continue
            lines = block.split("\n")
            headline = lines[0].strip()
            if re.match(r"^[🚀💡🔥📊⚡🧠🤖🎯🤝💻]", headline) and len(lines) < 2:
                continue
            if re.match(r"^[🚀💡🔥📊⚡🧠🤖🎯🤝💻]", headline) and len(headline) < 56:
                if len(lines) > 1:
                    headline = lines[1].strip()
                    summary_text = "\n".join(lines[2:]).strip()
                else:
                    continue
            else:
                summary_text = "\n".join(lines[1:]).strip()

            headline = re.sub(r"\s*\[link\]\s*$", "", headline, flags=re.IGNORECASE)
            headline = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", headline)
            headline = headline.strip("*# ")

            if len(headline) < 5:
                continue
            if _is_section_header_headline(headline):
                continue
            if headline.lower() in ("links", "link", "links:", "sponsor", "sponsors"):
                continue

            summary_text = clean_summary(re.sub(r"\s+", " ", summary_text)[:800])
            urls = extract_urls(block)
            links = [
                {"url": u, "context": summary_text[:200], "type": link_type_for_url(u)}
                for u in urls[:12]
            ]
            stories.append(
                {
                    "headline": headline[:300],
                    "summary": summary_text or clean_summary(headline) or headline,
                    "links": links,
                    "categories": infer_categories(headline, summary_text),
                }
            )

    return stories, notable_apps


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
            headline_clean = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", headline_raw)
            if _is_section_header_headline(headline_clean):
                continue
            urls = extract_urls(chunk)
            summary = clean_summary(re.sub(r"\s+", " ", chunk)[:800])
            links = [
                {"url": u, "context": summary[:200], "type": link_type_for_url(u)}
                for u in urls[:12]
            ]
            stories.append(
                {
                    "headline": headline_clean[:300],
                    "summary": summary or clean_summary(headline_clean) or headline_clean,
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
            if _is_section_header_headline(headline):
                continue
            urls = extract_urls(chunk)
            if not urls and len(chunk) < 20:
                continue
            summary = clean_summary(re.sub(r"\s+", " ", chunk)[:800])
            links = []
            for u in urls[:12]:
                links.append({"url": u, "context": summary[:200], "type": link_type_for_url(u)})
            stories.append(
                {
                    "headline": headline[:300],
                    "summary": summary or clean_summary(headline) or headline,
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
            if _is_section_header_headline(first):
                continue
            rest = blk[len(first) :].strip() if len(blk) > len(first) else blk
            summary = clean_summary(re.sub(r"\s+", " ", rest)[:800])
            links = [
                {"url": u, "context": summary[:200], "type": link_type_for_url(u)}
                for u in urls[:12]
            ]
            stories.append(
                {
                    "headline": first,
                    "summary": summary or clean_summary(first) or first,
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
    blob = (body or "").replace("\r\n", "\n").replace("\r", "\n")
    subj = subject or ""
    fe = (from_email or "").lower()
    is_tldr = (
        "tldr.tech" in blob.lower()
        or "readtldr.com" in blob.lower()
        or "tldrnewsletter.com" in fe
        or "TLDR AI" in subj
    )
    is_substack = "substack.com/redirect" in blob or "View this post on the web" in blob

    if is_tldr:
        stories, notable_apps = parse_tldr_stories(blob)
        if not stories:
            stories, notable_apps = parse_stories_the_neuron_style(blob)
    elif is_substack:
        stories, notable_apps = parse_substack_stories(blob)
        if not stories:
            stories, notable_apps = parse_stories_the_neuron_style(blob)
    else:
        stories, notable_apps = parse_stories_the_neuron_style(blob)

    for st in stories:
        st["summary"] = clean_summary(st.get("summary") or "")

    raw_links = extract_urls(blob)
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
        "body_text": blob[:BODY_TEXT_DEBUG_LIMIT],
    }


def from_email_trusted_sender(from_email: str, subject: str) -> bool:
    fe = from_email.lower()
    if fe in AI_ML_SENDERS:
        return True
    dom = fe.split("@")[-1] if "@" in fe else ""
    if dom in AI_ML_SENDER_DOMAINS and AI_ML_DOMAIN_SUBJECT.search(subject or ""):
        return True
    return False


def is_ai_ml_newsletter(from_email: str, subject: str, body: str) -> bool:
    fe = from_email.lower()
    if any(b in fe for b in BLOCKED_SENDERS):
        return False
    if from_email_trusted_sender(from_email, subject):
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
            bt = new_data.get("body_text")
            if bt:
                old["body_text"] = str(bt)[:BODY_TEXT_DEBUG_LIMIT]
            mids = list(old.get("message_ids", []))
            mid = new_data.get("message_id", "")
            if mid and mid not in mids:
                mids.append(mid)
            old["message_ids"] = mids
            with open(path, "w", encoding="utf-8") as f:
                json.dump(old, f, indent=2)
            return
    out = dict(new_data)
    out["body_text"] = (new_data.get("body_text") or "")[:BODY_TEXT_DEBUG_LIMIT]
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

                sender_review = not from_email_trusted_sender(
                    from_addr, subject
                ) and bool(SUBJECT_AI_KEYWORDS.search(subject or ""))

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
