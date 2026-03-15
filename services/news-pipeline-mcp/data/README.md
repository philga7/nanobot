# News pipeline data (topics)

Topics are **only** loaded from files—never hard-coded in code. Badge logic (e.g. CitizenFreePress BREAKING/LIVE) stays in code.

- **`priority-topics.md`** – One topic per line. Items matching title/snippet get a ×1.5 score multiplier.
- **`major-events.md`** – One keyword per line (case-insensitive). Title matches get +2 score.

**Location:** The service reads from `NEWS_DATA_DIR` if set, otherwise `{NANOBOT_BASE_DIR}/news`. Copy this folder there or set `NEWS_DATA_DIR` to this `data/` directory (e.g. when running from repo).

**Format:** Lines can use markdown list markers (`-`, `*`, `#`) or numbers; they are stripped. Empty lines are ignored.
