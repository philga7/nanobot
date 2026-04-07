#!/bin/bash
# Polls Hostinger IMAP inbox for dividend/investing newsletters and extracts
# actionable signals (special dividends, hikes, cuts, sector commentary).
#
# Install:
#   cp /path/to/skill/scripts/newsletter-ingest.sh ~/.wrenvps/scripts/
#   chmod +x ~/.wrenvps/scripts/newsletter-ingest.sh
#
# Cron: 45 6 * * 1-5 (America/New_York) — weekdays 6:45 AM ET
# (runs 10 minutes before special_dividend_scanner at 6:55 AM)
#
# Output: ~/.wrenvps/dividend-intel/newsletter_signals.json
# Idempotency: processed message IDs tracked in ~/.wrenvps/dividend-intel/newsletter_processed_ids.json

python3 << 'EOF'
import imaplib
import email
import email.header
import html.parser
import json
import os
import re
import sys
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime

CREDS_PATH      = os.path.expanduser("~/.wrenvps/dividend-intel/email_creds.json")
SIGNALS_PATH    = os.path.expanduser("~/.wrenvps/dividend-intel/newsletter_signals.json")
PROCESSED_PATH  = os.path.expanduser("~/.wrenvps/dividend-intel/newsletter_processed_ids.json")

# ── Credentials ──────────────────────────────────────────────────────────────
try:
    with open(CREDS_PATH, encoding="utf-8") as f:
        creds = json.load(f)
    IMAP_HOST = creds["host"]
    IMAP_PORT = int(creds.get("port", 993))
    IMAP_USER = creds["username"]
    IMAP_PASS = creds["password"]
    IMAP_SSL  = bool(creds.get("ssl", True))
except FileNotFoundError:
    print(f"ERROR: credentials not found at {CREDS_PATH}", file=sys.stderr)
    sys.exit(1)
except (KeyError, json.JSONDecodeError) as e:
    print(f"ERROR: bad credentials file: {e}", file=sys.stderr)
    sys.exit(1)

# ── HTML stripping ────────────────────────────────────────────────────────────
class _HTMLStripper(html.parser.HTMLParser):
    def __init__(self):
        super().__init__()
        self._parts = []

    def handle_data(self, data):
        self._parts.append(data)

    def get_text(self):
        return " ".join(self._parts)

def strip_html(html_text):
    stripper = _HTMLStripper()
    try:
        stripper.feed(html_text)
    except Exception:
        pass
    return stripper.get_text()

# ── Email body extraction ─────────────────────────────────────────────────────
def get_body(msg):
    """Return plain-text body. Prefer text/plain; fall back to stripped HTML."""
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
        return plain
    if html_body:
        return strip_html(html_body)
    return ""

# ── Subject decoding ──────────────────────────────────────────────────────────
def decode_subject(raw_subject):
    parts = email.header.decode_header(raw_subject or "")
    decoded = []
    for part, charset in parts:
        if isinstance(part, bytes):
            decoded.append(part.decode(charset or "utf-8", errors="replace"))
        else:
            decoded.append(str(part))
    return " ".join(decoded)

# ── Ticker extraction ─────────────────────────────────────────────────────────
# Matches $TICKER or bare ALL-CAPS 1-5 letter words near dividend keywords.
_TICKER_RE = re.compile(r'\$([A-Z]{1,5})\b')
# Common false positives to exclude from bare-word extraction
_STOP_WORDS = {
    "I", "A", "AN", "THE", "AND", "OR", "NOT", "FOR", "IN", "ON", "AT",
    "TO", "OF", "IS", "IT", "AS", "BY", "BE", "DO", "IF", "UP", "SO",
    "NO", "US", "IRS", "SEC", "ETF", "CEO", "CFO", "IPO", "EPS", "NII",
    "FFO", "NAV", "BDC", "MLP", "REIT", "SMA", "ETFs", "Q1", "Q2", "Q3",
    "Q4", "FY", "YTD", "YOY", "QOQ", "AM", "PM", "EST", "EDT", "ET",
    "OK", "HI", "ALL", "NEW", "OLD", "LOW", "HIGH",
}

def extract_tickers(text):
    tickers = list({m.group(1) for m in _TICKER_RE.finditer(text)})
    # Also grab ALL-CAPS 1-5 letter words within 50 chars of a dividend keyword
    for m in re.finditer(
        r'(?:dividend|distribution|ex[\-\s]div|special|hike|cut|suspension)',
        text, re.IGNORECASE
    ):
        start = max(0, m.start() - 150)
        end   = min(len(text), m.end() + 150)
        window = text[start:end]
        for word in re.findall(r'\b([A-Z]{1,5})\b', window):
            if word not in _STOP_WORDS and len(word) >= 2:
                if word not in tickers:
                    tickers.append(word)
    return tickers[:10]  # cap at 10 to avoid noise

# ── Signal parsing ────────────────────────────────────────────────────────────
# Keyword sets for each signal type.
_SPECIAL_DIV_KWS = re.compile(
    r'special\s+(?:cash\s+)?dividend|extra\s+dividend|one[\-\s]time\s+dividend|'
    r'extraordinary\s+dividend|special\s+distribution',
    re.IGNORECASE,
)
_DIV_HIKE_KWS = re.compile(
    r'dividend\s+(?:increase|hike|raise|boost|growth|raised|increased)|'
    r'increases?\s+(?:its\s+)?(?:quarterly\s+)?dividend|'
    r'raises?\s+(?:its\s+)?(?:quarterly\s+)?dividend',
    re.IGNORECASE,
)
_DIV_CUT_KWS = re.compile(
    r'dividend\s+(?:cut|reduction|suspension|eliminated?|halted?|suspended?|'
    r'reduced?|lower(?:ed)?|slash(?:ed)?)|'
    r'suspend(?:s|ed)?\s+(?:its\s+)?dividend|'
    r'eliminat(?:es?|ed)\s+(?:its\s+)?dividend',
    re.IGNORECASE,
)
_SECTOR_KWS = re.compile(
    r'dividend\s+stock|dividend\s+investor|income\s+(?:investor|portfolio|stock)|'
    r'ex[\-\s]dividend\s+date|record\s+date|payout\s+ratio|dividend\s+yield|'
    r'dividend\s+growth|dividend\s+aristocrat|dividend\s+king',
    re.IGNORECASE,
)

# Dollar amount patterns near dividend keywords: $X.XX or X.XX per share
_AMOUNT_RE = re.compile(r'\$\s*(\d+\.?\d*)\s*(?:per\s+share)?|\b(\d+\.?\d*)\s*cents?\s+per\s+share', re.IGNORECASE)
# Date patterns: Month DD, YYYY or YYYY-MM-DD
_DATE_RE = re.compile(
    r'\b(?:January|February|March|April|May|June|July|August|September|October|November|December)'
    r'\s+\d{1,2},?\s+\d{4}|\b\d{4}-\d{2}-\d{2}\b',
    re.IGNORECASE,
)

def score_confidence(signal_type, tickers, text_excerpt):
    """High = ticker + amount + date all found. Medium = ticker + keyword. Low = keyword only."""
    has_ticker = bool(tickers)
    has_amount = bool(_AMOUNT_RE.search(text_excerpt))
    has_date   = bool(_DATE_RE.search(text_excerpt))

    if signal_type == "sector_commentary":
        return "low"
    if has_ticker and has_amount and has_date:
        return "high"
    if has_ticker and (has_amount or has_date):
        return "medium"
    if has_ticker:
        return "medium"
    return "low"

def extract_excerpt(text, match_obj, radius=300):
    """Return a ~600-char excerpt centered on the match."""
    start = max(0, match_obj.start() - radius)
    end   = min(len(text), match_obj.end() + radius)
    excerpt = text[start:end].strip()
    return excerpt[:600]

def parse_signals(body, subject, from_addr, date_str):
    """Return a list of signal dicts extracted from one email."""
    signals = []
    seen_types = set()

    checks = [
        ("special_dividend", _SPECIAL_DIV_KWS),
        ("dividend_hike",    _DIV_HIKE_KWS),
        ("dividend_cut",     _DIV_CUT_KWS),
        ("sector_commentary", _SECTOR_KWS),
    ]

    # Determine sender/source label
    source = from_addr.split("@")[-1].split(">")[-1].strip().rstrip(">") if from_addr else "unknown"
    # Clean up source to a readable label
    source = re.sub(r'[<>]', '', source).strip()

    for signal_type, pattern in checks:
        m = pattern.search(body)
        if not m:
            # Also check subject
            ms = pattern.search(subject)
            if not ms:
                continue
            m = ms
            excerpt = subject
        else:
            excerpt = extract_excerpt(body, m)

        # Avoid emitting duplicate signal types from the same email
        if signal_type in seen_types:
            continue
        seen_types.add(signal_type)

        tickers = extract_tickers(excerpt + " " + subject)
        confidence = score_confidence(signal_type, tickers, excerpt)

        # Build a short summary line
        summary_parts = []
        if tickers:
            summary_parts.append(f"Tickers: {', '.join(tickers[:5])}")
        amounts = _AMOUNT_RE.findall(excerpt)
        for a, b in amounts[:2]:
            val = a or b
            if val:
                summary_parts.append(f"amount ~${val}")
        dates = _DATE_RE.findall(excerpt)
        if dates:
            summary_parts.append(f"date ref: {dates[0]}")
        summary = "; ".join(summary_parts) if summary_parts else f"{signal_type} mentioned in newsletter"

        signals.append({
            "source": source,
            "sourceType": "newsletter",
            "date": date_str,
            "subject": subject[:200],
            "signalType": signal_type,
            "tickers": tickers[:10],
            "summary": summary[:300],
            "confidence": confidence,
            "rawExcerpt": excerpt[:600],
        })

    return signals

# ── Processed IDs tracking ────────────────────────────────────────────────────
def load_processed_ids():
    try:
        with open(PROCESSED_PATH, encoding="utf-8") as f:
            return set(json.load(f))
    except (FileNotFoundError, json.JSONDecodeError):
        return set()

def save_processed_ids(ids):
    os.makedirs(os.path.dirname(PROCESSED_PATH), exist_ok=True)
    with open(PROCESSED_PATH, "w", encoding="utf-8") as f:
        json.dump(sorted(ids), f, indent=2)

# ── Existing signals loading ──────────────────────────────────────────────────
def load_existing_signals():
    try:
        with open(SIGNALS_PATH, encoding="utf-8") as f:
            data = json.load(f)
        return data.get("signals", [])
    except (FileNotFoundError, json.JSONDecodeError):
        return []

# ── Main ──────────────────────────────────────────────────────────────────────
processed_ids = load_processed_ids()
existing_signals = load_existing_signals()
new_signals = []
errors = []

try:
    if IMAP_SSL:
        conn = imaplib.IMAP4_SSL(IMAP_HOST, IMAP_PORT)
    else:
        conn = imaplib.IMAP4(IMAP_HOST, IMAP_PORT)

    conn.login(IMAP_USER, IMAP_PASS)
    conn.select("INBOX")

    # Fetch all unseen messages
    status, data = conn.search(None, "UNSEEN")
    if status != "OK":
        raise RuntimeError(f"IMAP SEARCH failed: {status}")

    msg_ids = data[0].split() if data[0] else []
    print(f"Found {len(msg_ids)} unread messages", flush=True)

    for msg_id_bytes in msg_ids:
        msg_id_str = msg_id_bytes.decode()
        try:
            # Fetch full RFC822 message
            status, msg_data = conn.fetch(msg_id_bytes, "(RFC822 UID)")
            if status != "OK":
                errors.append(f"msg {msg_id_str}: FETCH failed ({status})")
                continue

            raw_email = None
            uid_str = msg_id_str
            for part in msg_data:
                if isinstance(part, tuple) and part[0].endswith(b")") or isinstance(part, tuple):
                    if b"RFC822" in part[0] if isinstance(part[0], bytes) else False:
                        raw_email = part[1]
                    elif isinstance(part[1], bytes) and len(part[1]) > 100:
                        raw_email = part[1]

            # Simpler extraction: just grab the big bytes blob
            for item in msg_data:
                if isinstance(item, tuple) and isinstance(item[1], bytes) and len(item[1]) > 200:
                    raw_email = item[1]
                    break

            if raw_email is None:
                errors.append(f"msg {msg_id_str}: no RFC822 content")
                continue

            # Parse message
            msg = email.message_from_bytes(raw_email)

            # Build a stable unique ID: Message-ID header or fallback
            message_id_header = msg.get("Message-ID", "").strip()
            unique_id = message_id_header if message_id_header else f"seq:{msg_id_str}"

            if unique_id in processed_ids:
                # Already processed in a prior run — mark read and skip
                conn.store(msg_id_bytes, "+FLAGS", "\\Seen")
                continue

            subject  = decode_subject(msg.get("Subject", ""))
            from_raw = msg.get("From", "")
            date_raw = msg.get("Date", "")

            # Parse date
            try:
                date_dt  = parsedate_to_datetime(date_raw)
                date_str = date_dt.strftime("%Y-%m-%d")
            except Exception:
                date_str = datetime.now(tz=timezone.utc).strftime("%Y-%m-%d")

            body = get_body(msg)

            # Only process if email has dividend-related content
            combined_text = subject + " " + body
            if not re.search(
                r'dividend|distribution|ex[\-\s]div|payout|yield|income\s+stock',
                combined_text, re.IGNORECASE
            ):
                # Not dividend-related — mark read, record as processed, skip
                conn.store(msg_id_bytes, "+FLAGS", "\\Seen")
                processed_ids.add(unique_id)
                continue

            signals = parse_signals(body, subject, from_raw, date_str)

            if signals:
                new_signals.extend(signals)
                print(f"  msg {msg_id_str} [{subject[:60]}]: {len(signals)} signal(s)", flush=True)
            else:
                print(f"  msg {msg_id_str} [{subject[:60]}]: no signals extracted", flush=True)

            # Mark as read and record processed ID
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

# ── Merge and write output ────────────────────────────────────────────────────
all_signals = existing_signals + new_signals
os.makedirs(os.path.dirname(SIGNALS_PATH), exist_ok=True)
output = {
    "lastChecked": datetime.now(tz=timezone.utc).isoformat(),
    "signals": all_signals,
}
with open(SIGNALS_PATH, "w", encoding="utf-8") as f:
    json.dump(output, f, indent=2)

save_processed_ids(processed_ids)

print(f"\nDone. New signals: {len(new_signals)} | Total signals: {len(all_signals)} | Errors: {len(errors)}")
for e in errors:
    print(f"  {e}", file=sys.stderr)
EOF
