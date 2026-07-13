"""garmin_sync_lib の単体テスト。"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

from datetime import time

from garmin_sync_lib import (  # noqa: E402
    enqueue_date_range,
    inline_or_storage_plan,
    is_postgres_unique_violation,
    json_safe,
    maybe_single_row,
    parse_garmin_start_time,
    response_data,
)


def test_parse_garmin_start_time_prefers_gmt() -> None:
    act = {
        "startTimeGMT": "2026-04-21 02:30:00",
        "startTimeLocal": "2026-04-21 06:30:00",
    }
    assert parse_garmin_start_time(act) == "2026-04-21T02:30:00+00:00"


def test_parse_garmin_start_time_local_as_jst() -> None:
    act = {"startTimeLocal": "2026-04-21 06:30:00"}
    result = parse_garmin_start_time(act)
    assert result is not None
    assert result.startswith("2026-04-20T21:30:00") or result.startswith("2026-04-21T")


def test_enqueue_date_range() -> None:
    assert enqueue_date_range(["2026-07-10", "2026-07-05", "2026-07-08"]) == (
        "2026-07-05",
        "2026-07-10",
    )
    assert enqueue_date_range([]) is None


def test_inline_or_storage_plan_small() -> None:
    payload = {"a": 1}
    inline, use_storage = inline_or_storage_plan(payload, max_bytes=1024)
    assert inline == payload
    assert use_storage is False


def test_inline_or_storage_plan_large() -> None:
    payload = {"data": "x" * 2000}
    inline, use_storage = inline_or_storage_plan(payload, max_bytes=100)
    assert use_storage is True
    assert inline["_bytes"] > 100


def test_is_postgres_unique_violation() -> None:
    assert is_postgres_unique_violation(Exception("duplicate key value violates unique constraint"))
    assert is_postgres_unique_violation(Exception("23505"))
    assert not is_postgres_unique_violation(Exception("connection refused"))


class _FakeResponse:
    def __init__(self, data):
        self.data = data


def test_json_safe_time() -> None:
    assert json_safe(time(12, 30, 0)) == "12:30:00"


def test_response_data_handles_none_execute() -> None:
    assert response_data(None) is None
    assert response_data(_FakeResponse([{"id": 1}])) == [{"id": 1}]


def test_maybe_single_row_normalizes_supabase_responses() -> None:
    assert maybe_single_row(None) is None
    assert maybe_single_row(_FakeResponse(None)) is None
    assert maybe_single_row(_FakeResponse({"sync_status": "complete"})) == {
        "sync_status": "complete",
    }
    assert maybe_single_row(_FakeResponse([{"sync_status": "partial"}])) == {
        "sync_status": "partial",
    }
    assert maybe_single_row(_FakeResponse([])) is None


if __name__ == "__main__":
    test_parse_garmin_start_time_prefers_gmt()
    test_parse_garmin_start_time_local_as_jst()
    test_enqueue_date_range()
    test_inline_or_storage_plan_small()
    test_inline_or_storage_plan_large()
    test_is_postgres_unique_violation()
    test_json_safe_time()
    test_response_data_handles_none_execute()
    test_maybe_single_row_normalizes_supabase_responses()
    print("all tests passed")
