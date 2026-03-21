"""News skill configuration — channels, thresholds, delivery settings."""

from __future__ import annotations

import os

SLACK_CHANNEL = "#breaking-news"
NTFY_TOPIC = "wrenvps-notifications"
NTFY_URL = os.environ.get("NTFY_URL", "")
NTFY_TOKEN = os.environ.get("NTFY_TOKEN", "")
NTFY_THRESHOLD = 10
ENRICHMENT_THRESHOLD = 7
MAX_ITEMS_PER_RUN = 10
CRON_SCHEDULE = "*/15 6-23 * * *"
