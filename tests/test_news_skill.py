"""Tests for the news skill."""

from nanobot.news.agent import _build_analyst_note
from nanobot.news.config import (
    CRON_SCHEDULE,
    ENRICHMENT_THRESHOLD,
    NTFY_THRESHOLD,
    SLACK_CHANNEL,
)
from nanobot.news.templates import (
    build_ntfy_message,
    build_slack_message,
    delivery_targets,
    ntfy_headline,
    slack_headline,
)


class TestConfig:
    def test_slack_channel(self) -> None:
        assert SLACK_CHANNEL == "#breaking-news"

    def test_ntfy_threshold(self) -> None:
        assert NTFY_THRESHOLD == 10

    def test_enrichment_threshold(self) -> None:
        assert ENRICHMENT_THRESHOLD == 7

    def test_cron_schedule(self) -> None:
        assert CRON_SCHEDULE == "*/15 6-23 * * *"


class TestTemplates:
    def test_slack_headline_breaking(self) -> None:
        result = slack_headline("Senate passes budget", 10, True)
        assert ":rotating_light:" in result
        assert "BREAKING" in result
        assert "[10]" in result
        assert "Senate passes budget" in result

    def test_slack_headline_normal(self) -> None:
        result = slack_headline("Market update", 5, False)
        assert ":rotating_light:" not in result
        assert "BREAKING" not in result
        assert "[5]" in result

    def test_ntfy_headline(self) -> None:
        result = ntfy_headline("Treasury announces new tariffs", 10)
        assert "BREAKING [10]" in result
        assert "Treasury announces" in result

    def test_build_slack_message(self) -> None:
        items = [
            {
                "title": "Test Story",
                "url": "https://example.com/test",
                "score": 8,
                "is_breaking": True,
                "osint_tags": ["geopolitics", "markets"],
                "analyst_note": "High impact.",
            }
        ]
        result = build_slack_message(items, "breaking-news", "Breaking News", "#breaking-news")
        assert "Test Story" in result
        assert "https://example.com/test" in result
        assert "example.com" in result
        assert "• Test Story" in result
        assert "[8]" not in result
        assert "geopolitics" not in result

    def test_build_slack_message_empty(self) -> None:
        result = build_slack_message([], "breaking-news", "Breaking News", "#breaking-news")
        assert result == ""

    def test_build_ntfy_message(self) -> None:
        items = [
            {"title": "Breaking Story One", "score": 10},
            {"title": "Breaking Story Two", "score": 12},
        ]
        result = build_ntfy_message(items, "Breaking News")
        assert "Breaking News" in result
        assert "[10]" in result
        assert "[12]" in result

    def test_build_ntfy_message_empty(self) -> None:
        result = build_ntfy_message([], "Breaking News")
        assert result == ""

    def test_delivery_targets_ntfy_eligible(self) -> None:
        targets = delivery_targets(10)
        assert targets["ntfy"] is True

    def test_delivery_targets_below_threshold(self) -> None:
        targets = delivery_targets(9)
        assert targets["ntfy"] is False


class TestAgentHelpers:
    def test_build_analyst_note_with_orgs_and_locs(self) -> None:
        entities = {
            "people": ["John Doe"],
            "organizations": ["NATO", "EU Commission"],
            "locations": ["Kyiv", "Brussels"],
            "threat_indicators": ["sanctions"],
        }
        result = _build_analyst_note(entities, ["geopolitics"])
        assert "NATO" in result
        assert "EU Commission" in result
        assert "Kyiv" in result
        assert "Brussels" in result

    def test_build_analyst_note_empty(self) -> None:
        entities: dict = {}
        result = _build_analyst_note(entities, [])
        assert result == ""
