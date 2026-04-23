#!/usr/bin/env python3
"""Send stdin text to Telegram sendMessage; split into chunks under the API limit."""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request

# Margin below Telegram's 4096 limit for safety with UTF-8 expansion / edits.
CHUNK = 4000


def _chunk_text(text: str, max_len: int = CHUNK) -> list[str]:
    text = text or ""
    if not text.strip():
        return []
    parts: list[str] = []
    rest = text
    while rest:
        if len(rest) <= max_len:
            parts.append(rest)
            break
        cut = rest.rfind("\n\n", 0, max_len)
        if cut < max_len // 3:
            cut = rest.rfind("\n", 0, max_len)
        if cut < max_len // 3:
            cut = max_len
        parts.append(rest[:cut])
        rest = rest[cut:].lstrip("\n")
    return parts


def main() -> int:
    chat = (sys.argv[1] if len(sys.argv) > 1 else "").strip()
    token = (os.environ.get("NANOBOT_CHANNELS__TELEGRAM__TOKEN") or "").strip()
    if not token or not chat:
        return 0
    message = sys.stdin.read()
    if not message.strip():
        return 0
    url = f"https://api.telegram.org/bot{token}/sendMessage"
    for part in _chunk_text(message, CHUNK):
        payload = json.dumps(
            {
                "chat_id": chat,
                "text": part,
                "disable_web_page_preview": True,
            }
        ).encode("utf-8")
        req = urllib.request.Request(
            url,
            data=payload,
            headers={"Content-Type": "application/json; charset=utf-8"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=45) as resp:
                raw = resp.read().decode("utf-8", errors="replace")
        except urllib.error.URLError as e:
            print(f"OSINT telegram_send: {e}", file=sys.stderr)
            return 1
        try:
            body = json.loads(raw)
        except json.JSONDecodeError:
            print("OSINT telegram_send: invalid JSON response", file=sys.stderr)
            return 1
        if not body.get("ok"):
            print(f"OSINT telegram_send: {raw[:500]}", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
