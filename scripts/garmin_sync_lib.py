"""Garmin Sync Job 共通ロジック（単体テスト対象）。"""

from __future__ import annotations

import json
from datetime import UTC, datetime
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
