"""Tests for bundled net-monitor skill scripts."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path
from shutil import which

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
CHECK_SH = REPO_ROOT / "nanobot/skills/net-monitor/scripts/check.sh"
ALERT_SH = REPO_ROOT / "nanobot/skills/net-monitor/scripts/alert.sh"
FIXTURE = REPO_ROOT / "tests/fixtures/net_monitor_sample.json"
FIXTURE_DOWN = REPO_ROOT / "tests/fixtures/net_monitor_internet_down.json"


def _bash_executable() -> str:
    """Resolve bash for subprocess.

    On Windows, ``bash`` in PATH is often the WSL stub (fails with no distro).
    GitHub Actions and developer machines typically ship Git for Windows —
    prefer ``.../Git/bin/bash.exe`` when present.
    """
    if sys.platform == "win32":
        for env_key in ("ProgramFiles", "ProgramFiles(x86)"):
            root = os.environ.get(env_key)
            if not root:
                continue
            candidate = Path(root) / "Git" / "bin" / "bash.exe"
            if candidate.is_file():
                return str(candidate)
        pytest.skip(
            "Git Bash not found under Program Files; "
            "PATH `bash` is not usable for these script tests on this Windows host."
        )
    resolved = which("bash")
    if not resolved:
        pytest.skip("bash not found on PATH")
    return resolved


def test_net_monitor_scripts_bash_syntax() -> None:
    bash = _bash_executable()
    subprocess.run([bash, "-n", str(CHECK_SH)], check=True)
    subprocess.run([bash, "-n", str(ALERT_SH)], check=True)


def test_net_monitor_alert_dry_run_ok_fixture(tmp_path: Path) -> None:
    bash = _bash_executable()
    cache = tmp_path / "last_alert.json"
    env = {
        **os.environ,
        "NET_MONITOR_NTFY_URL": "",
        "NET_MONITOR_CACHE_FILE": str(cache),
    }
    r = subprocess.run(
        [bash, str(ALERT_SH), "--dry-run", str(FIXTURE)],
        capture_output=True,
        text=True,
        env=env,
        check=False,
    )
    assert r.returncode == 0, r.stderr


def test_net_monitor_alert_dry_run_critical_fixture(tmp_path: Path) -> None:
    bash = _bash_executable()
    cache = tmp_path / "last_alert.json"
    env = {
        **os.environ,
        "NET_MONITOR_NTFY_URL": "",
        "NET_MONITOR_CACHE_FILE": str(cache),
    }
    r = subprocess.run(
        [bash, str(ALERT_SH), "--dry-run", str(FIXTURE_DOWN)],
        capture_output=True,
        text=True,
        env=env,
        check=False,
    )
    assert r.returncode == 0, r.stderr
    assert "CRITICAL" in r.stdout or "dry-run" in r.stdout.lower()


@pytest.mark.skipif(
    not os.environ.get("NET_MONITOR_INTEGRATION"),
    reason="Set NET_MONITOR_INTEGRATION=1 to run live check.sh (ICMP, ~30s).",
)
def test_net_monitor_check_live_json_schema() -> None:
    bash = _bash_executable()
    r = subprocess.run(
        [bash, str(CHECK_SH)],
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )
    assert r.returncode == 0, r.stderr
    data = json.loads(r.stdout)
    assert data["alert"] is None
    for key in ("timestamp", "internet", "wireguard", "tailscale", "home_network"):
        assert key in data
    assert data["internet"]["status"] in ("up", "down", "degraded")
    assert "packet_loss_pct" in data["internet"]
