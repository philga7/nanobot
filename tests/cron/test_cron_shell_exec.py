import json

import pytest

from nanobot.agent.tools.cron import CronTool, _message_looks_like_shell_exec
from nanobot.cron.service import CronService
from nanobot.cron.types import CronSchedule


@pytest.mark.parametrize(
    ("message", "expected"),
    [
        ("bash /root/.wrenvps/scripts/backup.sh", True),
        ("/bin/sh -c 'echo hi'", True),
        ("./scripts/run.sh", True),
        ("/usr/local/bin/backup", True),
        ("Remind me to run bash later", False),
        ("bash\nsecond line", False),
        ("", False),
    ],
)
def test_shell_message_heuristic(message: str, expected: bool) -> None:
    assert _message_looks_like_shell_exec(message) is expected


def test_add_job_shell_exec_strips_delivery_fields(tmp_path) -> None:
    store_path = tmp_path / "cron" / "jobs.json"
    service = CronService(store_path)
    service.add_job(
        name="bk",
        schedule=CronSchedule(kind="every", every_ms=60_000),
        message="bash /tmp/x.sh",
        deliver=True,
        channel="telegram",
        to="1461042142",
        payload_kind="shell_exec",
    )
    job = service.list_jobs()[0]
    assert job.payload.kind == "shell_exec"
    assert job.payload.deliver is False
    assert job.payload.channel is None
    assert job.payload.to is None

    # When the service is not running, adds are appended to action.jsonl (merged on load).
    action_path = tmp_path / "cron" / "action.jsonl"
    line = json.loads(action_path.read_text(encoding="utf-8").strip().splitlines()[-1])
    assert line["action"] == "add"
    p = line["params"]["payload"]
    filtered = {k: v for k, v in p.items() if v is not None and v != {}}
    assert filtered == {
        "kind": "shell_exec",
        "message": "bash /tmp/x.sh",
        "deliver": False,
    }


@pytest.mark.asyncio
async def test_cron_tool_shell_style_job_without_channel(tmp_path) -> None:
    tool = CronTool(CronService(tmp_path / "cron" / "jobs.json"))
    result = await tool.execute(
        action="add",
        message="bash /root/.wrenvps/scripts/backup.sh",
        every_seconds=60,
    )
    assert "Created job" in result
    job = tool._cron.list_jobs()[0]
    assert job.payload.kind == "shell_exec"
    assert job.payload.deliver is False
    assert job.payload.channel is None
    assert job.payload.to is None


@pytest.mark.asyncio
async def test_cron_tool_agent_job_requires_channel(tmp_path) -> None:
    tool = CronTool(CronService(tmp_path / "cron" / "jobs.json"))
    result = await tool.execute(action="add", message="Remind me about the meeting", every_seconds=60)
    assert "chat session" in result


@pytest.mark.asyncio
async def test_cron_tool_shell_exec_false_keeps_agent_turn(tmp_path) -> None:
    from nanobot.agent.tools.context import RequestContext

    tool = CronTool(CronService(tmp_path / "cron" / "jobs.json"))
    tool.set_context(
        RequestContext(channel="telegram", chat_id="1461042142", session_key="telegram:1461042142"),
    )
    result = await tool.execute(
        action="add",
        message="bash /x.sh",
        every_seconds=60,
        shell_exec=False,
    )
    assert "Created job" in result
    job = tool._cron.list_jobs()[0]
    assert job.payload.kind == "agent_turn"
    assert job.payload.session_key == "telegram:1461042142"
    assert job.payload.origin_channel == "telegram"
    assert job.payload.origin_chat_id == "1461042142"
    assert job.payload.deliver is False
    assert job.payload.channel is None
    assert job.payload.to is None
