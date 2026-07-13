"""Garmin Sync Job 共通ロジック（単体テスト対象）。"""

from __future__ import annotations

import json
from datetime import UTC, date, datetime, time, timedelta
from io import BytesIO
from typing import Any
from zoneinfo import ZoneInfo

TOKYO = ZoneInfo("Asia/Tokyo")
JSON_INLINE_MAX_DEFAULT = 524288


def json_safe(obj: Any) -> Any:
    if isinstance(obj, bytes):
        return {"_type": "bytes", "length": len(obj)}
    if isinstance(obj, datetime):
        return obj.isoformat()
    if isinstance(obj, date):
        return obj.isoformat()
    if isinstance(obj, time):
        return obj.isoformat()
    if isinstance(obj, timedelta):
        return obj.total_seconds()
    if isinstance(obj, dict):
        return {k: json_safe(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [json_safe(v) for v in obj]
    return obj


def parse_garmin_start_time(activity: dict[str, Any]) -> str | None:
    """Garmin activity の開始時刻を UTC ISO8601 文字列に変換。

    training_log.start_time（UTC ISO8601）との突合に使う。
    startTimeGMT を優先し、無ければ startTimeLocal を JST として解釈する。
    """
    gmt = activity.get("startTimeGMT")
    if isinstance(gmt, str) and gmt.strip():
        return _parse_to_utc_iso(gmt.strip())

    local = activity.get("startTimeLocal")
    if isinstance(local, str) and local.strip():
        return _parse_to_utc_iso(local.strip(), assume_tz=TOKYO)

    return None


def _parse_to_utc_iso(raw: str, assume_tz: ZoneInfo | None = None) -> str | None:
    for fmt in (
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%dT%H:%M:%S",
        "%Y-%m-%dT%H:%M:%S.%f",
    ):
        try:
            dt = datetime.strptime(raw, fmt)
            if assume_tz is not None:
                dt = dt.replace(tzinfo=assume_tz)
            elif dt.tzinfo is None:
                dt = dt.replace(tzinfo=UTC)
            return dt.astimezone(UTC).isoformat()
        except ValueError:
            continue
    return None


def enqueue_date_range(dates: list[str]) -> tuple[str, str] | None:
    """HealthKit 同期レコードの date 列からキュー用 date_from/date_to を決定。"""
    if not dates:
        return None
    sorted_dates = sorted(dates)
    return sorted_dates[0], sorted_dates[-1]


def inline_or_storage_plan(
    payload: dict[str, Any], max_bytes: int = JSON_INLINE_MAX_DEFAULT
) -> tuple[dict[str, Any], bool]:
    """JSON をインライン保存するか Storage 退避するか判定。"""
    encoded = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    if len(encoded) <= max_bytes:
        return payload, False
    return {"_storage_path": "pending", "_bytes": len(encoded)}, True


def fit_to_json(fit_bytes: bytes) -> dict[str, Any]:
    try:
        import fitparse
    except ImportError:
        return {"_error": "fitparse not installed"}

    messages = []
    for msg in fitparse.FitFile(BytesIO(fit_bytes)).get_messages():
        messages.append({
            "name": msg.name,
            "fields": {f.name: json_safe(f.value) for f in msg.fields},
        })
    return {"messages": messages, "message_count": len(messages)}


def is_postgres_unique_violation(error: Exception) -> bool:
    message = str(error).lower()
    return "23505" in message or "duplicate" in message or "unique constraint" in message


def response_data(response: Any) -> Any:
    """supabase-py の execute() 結果から data を安全に取り出す。"""
    if response is None:
        return None
    return getattr(response, "data", None)


def maybe_single_row(response: Any) -> dict[str, Any] | None:
    """maybe_single().execute() の結果を 1 行 dict に正規化する。

    supabase-py 2.x では 0 行時に execute() 自体が None を返す。
    """
    data = response_data(response)
    if data is None:
        return None
    if isinstance(data, dict):
        return data
    if isinstance(data, list):
        return data[0] if data else None
    return None


def iter_dates(date_from: str, date_to: str) -> list[str]:
    """date_from..date_to（ISO date 文字列）の日付リスト。"""
    start = date.fromisoformat(date_from)
    end = date.fromisoformat(date_to)
    if start > end:
        return []
    days: list[str] = []
    current = start
    while current <= end:
        days.append(current.isoformat())
        current += timedelta(days=1)
    return days


def chunk_date_range(
    date_from: str, date_to: str, chunk_days: int
) -> list[tuple[str, str]]:
    """長期間を chunk_days 日単位の (from, to) に分割。"""
    if chunk_days < 1:
        raise ValueError("chunk_days must be >= 1")
    days = iter_dates(date_from, date_to)
    if not days:
        return []
    chunks: list[tuple[str, str]] = []
    for i in range(0, len(days), chunk_days):
        block = days[i : i + chunk_days]
        chunks.append((block[0], block[-1]))
    return chunks


def resolve_request_status(
    *,
    scope: str,
    activities_fetched: int = 0,
    activities_synced: int = 0,
    activities_skipped: int = 0,
    daily_fetched: int = 0,
    daily_synced: int = 0,
    daily_skipped: int = 0,
    step_errors: list[str] | None = None,
) -> tuple[str, str | None]:
    """garmin_sync_request の終了 status / error_message を決定。"""
    errors = step_errors or []
    if errors:
        return "partial", "; ".join(errors)

    if scope in ("activities", "all"):
        if activities_fetched == 0 and scope == "activities":
            return "partial", "No Garmin activities in date range"
        if scope == "all" and activities_fetched == 0 and daily_fetched == 0:
            return "partial", "No Garmin activities or daily data in date range"

    if scope in ("daily", "all"):
        if daily_fetched == 0 and scope == "daily":
            return "partial", "No daily dates processed"

    # 取得対象はあったがすべて idempotent skip → 成功扱い
    if scope == "activities":
        if activities_fetched > 0 and activities_synced == 0 and activities_skipped > 0:
            return "complete", None
    if scope == "daily":
        if daily_fetched > 0 and daily_synced == 0 and daily_skipped > 0:
            return "complete", None
    if scope == "all":
        act_done = activities_fetched == 0 or activities_synced > 0 or activities_skipped > 0
        day_done = daily_fetched == 0 or daily_synced > 0 or daily_skipped > 0
        if act_done and day_done:
            return "complete", None

    return "complete", None
