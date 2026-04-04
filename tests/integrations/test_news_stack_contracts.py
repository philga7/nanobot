from nanobot.integrations.news_stack import (
    NEWS_STACK_DECIDE_CONTEXT_KEY,
    CrucixSignal,
    DecideAndActContext,
    DecideAndActRequest,
    DecideAndActResponse,
    IngestSignalRequest,
    MemoryPoint,
    MemorySearchRequest,
    MemorySearchResponse,
    MemoryUpsertRequest,
    PlannedAction,
    build_api_path_process_direct_metadata,
)


def test_ingest_signal_contract_round_trip() -> None:
    signal = CrucixSignal(
        signal_id="sig-1",
        title="Major breaking development",
        summary="Short summary",
        tier="FLASH",
        tags=["osint", "breaking"],
    )
    req = IngestSignalRequest(signal=signal, dry_run=True)
    dumped = req.model_dump()

    assert dumped["signal"]["signal_id"] == "sig-1"
    assert dumped["signal"]["tier"] == "FLASH"
    assert dumped["dry_run"] is True


def test_decide_and_act_contract_includes_actions() -> None:
    req = DecideAndActRequest(
        context=DecideAndActContext(
            channel="telegram",
            chat_id="123",
            recent_messages=["what happened?"],
            metadata={"priority": "high"},
        )
    )
    assert req.context.channel == "telegram"

    resp = DecideAndActResponse(
        decision_id="dec-1",
        actions=[
            PlannedAction(
                action_type="notify_user",
                reason="Flash-tier signal should page operator",
                payload={"channel": "telegram", "message": "Urgent update"},
            )
        ],
        model="office-default",
    )
    assert resp.actions[0].action_type == "notify_user"


def test_memory_contracts_validate_limit_bounds() -> None:
    upsert = MemoryUpsertRequest(
        collection="intel",
        points=[
            MemoryPoint(
                point_id="p1",
                text="Signal context",
                vector=[0.1, 0.2, 0.3],
                metadata={"source": "crucix"},
            )
        ],
    )
    assert upsert.collection == "intel"

    search = MemorySearchRequest(collection="intel", query="latest signal", limit=5)
    assert search.limit == 5

    response = MemorySearchResponse(hits=[])
    assert response.hits == []


def test_api_path_metadata_contains_decide_context() -> None:
    meta = build_api_path_process_direct_metadata(
        session_key="api:custom",
        chat_id="default",
        user_message="hello api",
        http_request_id="rid-1",
    )
    assert NEWS_STACK_DECIDE_CONTEXT_KEY in meta
    inner = meta[NEWS_STACK_DECIDE_CONTEXT_KEY]
    assert inner["channel"] == "api"
    assert inner["metadata"]["session_key"] == "api:custom"
    assert inner["metadata"]["transport"] == "openai_api"
    assert inner["metadata"]["http_request_id"] == "rid-1"
    assert inner["recent_messages"] == ["hello api"]
