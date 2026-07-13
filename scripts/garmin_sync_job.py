#!/usr/bin/env python3
"""Garmin Sync Job — garmin_sync_request キューを処理する。

Phase 1.5+: scope=activities / daily / all
Ops: docs/garmin-sync-ops.md
"""

from __future__ import annotations

import json
import os
import sys
import zipfile
from datetime import UTC, datetime
from io import BytesIO
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

try:
    from garminconnect import Garmin
    from supabase import create_client
except ImportError:
    print("pip install garminconnect curl_cffi fitparse supabase", file=sys.stderr)
    sys.exit(1)

from garmin_fetchers import ACTIVITY_FETCHER_NAMES, DAILY_FETCHER_NAMES, call_daily_fetcher
from garmin_sync_lib import (
    JSON_INLINE_MAX_DEFAULT,
    fit_to_json,
    inline_or_storage_plan,
    iter_dates,
    json_safe,
    maybe_single_row,
    parse_garmin_start_time,
    resolve_request_status,
    response_data,
)

JSON_INLINE_MAX = int(os.environ.get("JSON_INLINE_MAX_BYTES", str(JSON_INLINE_MAX_DEFAULT)))
STALE_MINUTES = 30
PENDING_MAX_HOURS = 24


def _env(name: str) -> str:
    v = os.environ.get(name, "").strip()
    if not v:
        raise SystemExit(f"Missing env: {name}")
    return v


def _try_call(fn: Any, *args: Any) -> Any:
    try:
        return json_safe(fn(*args))
    except Exception as exc:  # noqa: BLE001
        return {"_error": type(exc).__name__, "message": str(exc)}


def load_users() -> list[dict[str, str]]:
    return json.loads(_env("GARMIN_SYNC_USERS"))


def login_garmin(sb: Any, user_id: str, email: str, password: str) -> Garmin:
    api = Garmin(email, password)
    token_row = maybe_single_row(
        sb.table("garmin_oauth_tokens")
        .select("token_store")
        .eq("user_id", user_id)
        .maybe_single()
        .execute()
    )
    tokenstore = (
        json.dumps(token_row["token_store"])
        if token_row and token_row.get("token_store")
        else None
    )

    if tokenstore and len(tokenstore) > 512:
        api.login(tokenstore=tokenstore)
    elif tokenstore:
        try:
            api.client.loads(tokenstore)
            api.get_user_profile()
        except Exception:
            api.login()
    else:
        api.login()

    sb.table("garmin_oauth_tokens").upsert({
        "user_id": user_id,
        "token_store": json.loads(api.client.dumps()),
        "updated_at": datetime.now(UTC).isoformat(),
    }).execute()
    return api


def prepare_queue(sb: Any) -> None:
    sb.rpc("reset_stale_garmin_sync_requests", {"stale_minutes": STALE_MINUTES}).execute()
    sb.rpc("expire_old_pending_garmin_sync_requests", {"max_age_hours": PENDING_MAX_HOURS}).execute()


def claim_request(sb: Any, request_id: str | None) -> dict[str, Any] | None:
    q = sb.table("garmin_sync_request").select("*").eq("status", "pending").order("requested_at")
    if request_id:
        q = q.eq("id", request_id)
    rows = response_data(q.limit(1).execute()) or []
    if not rows:
        return None
    req = rows[0]
    updated = (
        sb.table("garmin_sync_request")
        .update({"status": "running", "started_at": datetime.now(UTC).isoformat()})
        .eq("id", req["id"])
        .eq("status", "pending")
        .execute()
    )
    updated_rows = response_data(updated) or []
    if not updated_rows:
        return None
    return updated_rows[0]


def finish_request(
    sb: Any,
    req_id: str,
    status: str,
    error: str | None = None,
    progress: dict[str, Any] | None = None,
) -> None:
    payload: dict[str, Any] = {
        "status": status,
        "completed_at": datetime.now(UTC).isoformat(),
    }
    if error:
        payload["error_message"] = error
    if progress is not None:
        payload["progress"] = progress
    sb.table("garmin_sync_request").update(payload).eq("id", req_id).execute()


def already_synced_activity(sb: Any, user_id: str, activity_id: int) -> bool:
    row = maybe_single_row(
        sb.table("garmin_activity_archive")
        .select("sync_status")
        .eq("user_id", user_id)
        .eq("garmin_activity_id", activity_id)
        .maybe_single()
        .execute()
    )
    return row is not None and row.get("sync_status") == "complete"


def already_synced_daily(sb: Any, user_id: str, day: str) -> bool:
    row = maybe_single_row(
        sb.table("garmin_daily_archive")
        .select("sync_status")
        .eq("user_id", user_id)
        .eq("date", day)
        .maybe_single()
        .execute()
    )
    return row is not None and row.get("sync_status") == "complete"


def upload_json(sb: Any, path: str, payload: dict[str, Any]) -> str:
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    sb.storage.from_("garmin-json").upload(
        path, data, {"content-type": "application/json", "upsert": "true"}
    )
    return path


def upload_fit_zip(sb: Any, user_id: str, activity_id: int, raw: bytes) -> str:
    path = f"{user_id}/{activity_id}.zip"
    sb.storage.from_("garmin-fit").upload(
        path, raw, {"content-type": "application/zip", "upsert": "true"}
    )
    return path


def store_json_payload(
    sb: Any, user_id: str, storage_path: str, payload: dict[str, Any]
) -> tuple[dict[str, Any], str | None]:
    inline, use_storage = inline_or_storage_plan(payload, JSON_INLINE_MAX)
    if not use_storage:
        return inline, None
    path = f"{user_id}/{storage_path}"
    upload_json(sb, path, payload)
    inline["_storage_path"] = path
    return inline, path


def sync_activity(
    sb: Any, api: Garmin, user_id: str, act: dict[str, Any], request_id: str
) -> str:
    """1 activity を同期。'synced' | 'skipped' を返す。"""
    aid = act.get("activityId")
    if not aid:
        return "skipped"
    if already_synced_activity(sb, user_id, int(aid)):
        return "skipped"

    aid_str = str(aid)
    api_responses: dict[str, Any] = {"list_summary": act}
    errors: list[dict[str, str]] = []

    for name in ACTIVITY_FETCHER_NAMES:
        fn = getattr(api, name, None)
        if fn:
            api_responses[name] = _try_call(fn, aid_str)

    fit_parsed: dict[str, Any] = {}
    fit_storage_path: str | None = None
    try:
        raw_zip = api.download_activity(aid_str, dl_fmt=Garmin.ActivityDownloadFormat.ORIGINAL)
        fit_storage_path = upload_fit_zip(sb, user_id, int(aid), raw_zip)
        with zipfile.ZipFile(BytesIO(raw_zip)) as zf:
            for name in zf.namelist():
                if name.lower().endswith(".fit"):
                    fit_parsed = fit_to_json(zf.read(name))
                    break
    except Exception as exc:  # noqa: BLE001
        errors.append({"step": "fit_download", "error": str(exc)})

    summary = api_responses.get("get_activity") or act
    if isinstance(summary, dict) and "_error" in summary:
        summary = act

    inline_api, api_path = store_json_payload(
        sb, user_id, f"activities/{aid_str}_api.json", api_responses
    )
    inline_fit, fit_path = store_json_payload(
        sb, user_id, f"activities/{aid_str}_fit_parsed.json", fit_parsed
    )

    sync_status = "complete" if not errors else "partial"
    sb.table("garmin_activity_archive").upsert({
        "user_id": user_id,
        "garmin_activity_id": int(aid),
        "activity_type_key": (act.get("activityType") or {}).get("typeKey"),
        "activity_name": act.get("activityName"),
        "start_time_local": parse_garmin_start_time(act),
        "duration_sec": act.get("duration"),
        "summary": summary if isinstance(summary, dict) else {},
        "fit_parsed": inline_fit,
        "api_responses": inline_api,
        "fit_storage_path": fit_storage_path,
        "fit_parsed_storage_path": fit_path,
        "api_json_storage_path": api_path,
        "sync_request_id": request_id,
        "sync_status": sync_status,
        "sync_errors": errors,
        "synced_at": datetime.now(UTC).isoformat(),
    }, on_conflict="user_id,garmin_activity_id").execute()
    return "synced"


def sync_daily(
    sb: Any, api: Garmin, user_id: str, day: str, request_id: str
) -> str:
    """1 日分の日次 API を同期。'synced' | 'skipped' を返す。"""
    if already_synced_daily(sb, user_id, day):
        return "skipped"

    api_responses: dict[str, Any] = {}
    errors: list[dict[str, str]] = []
    for name in DAILY_FETCHER_NAMES:
        result = _try_call(call_daily_fetcher, api, name, day)
        api_responses[name] = result
        if isinstance(result, dict) and "_error" in result:
            errors.append({"step": name, "error": str(result.get("message", result["_error"]))})

    inline_api, api_path = store_json_payload(
        sb, user_id, f"daily/{day}.json", api_responses
    )
    sync_status = "complete" if not errors else "partial"
    sb.table("garmin_daily_archive").upsert({
        "user_id": user_id,
        "date": day,
        "api_responses": inline_api,
        "api_json_storage_path": api_path,
        "sync_request_id": request_id,
        "sync_status": sync_status,
        "sync_errors": errors,
        "synced_at": datetime.now(UTC).isoformat(),
    }, on_conflict="user_id,date").execute()
    return "synced"


def sync_activities_for_range(
    sb: Any, api: Garmin, user_id: str, date_from: str, date_to: str, request_id: str
) -> dict[str, int]:
    activities = api.get_activities_by_date(date_from, date_to)
    counts = {"fetched": len(activities), "synced": 0, "skipped": 0}
    for act in activities:
        result = sync_activity(sb, api, user_id, act, request_id)
        if result == "synced":
            counts["synced"] += 1
        else:
            counts["skipped"] += 1
    return counts


def sync_daily_for_range(
    sb: Any, api: Garmin, user_id: str, date_from: str, date_to: str, request_id: str
) -> dict[str, int]:
    days = iter_dates(date_from, date_to)
    counts = {"fetched": len(days), "synced": 0, "skipped": 0}
    for day in days:
        result = sync_daily(sb, api, user_id, day, request_id)
        if result == "synced":
            counts["synced"] += 1
        else:
            counts["skipped"] += 1
    return counts


def process_request(sb: Any, req: dict[str, Any], users_by_id: dict[str, dict[str, str]]) -> None:
    user_id = req["user_id"]
    cred = users_by_id.get(user_id)
    if not cred:
        finish_request(sb, req["id"], "failed", f"No credentials for user {user_id}")
        return

    scope = req["scope"]
    if scope not in ("activities", "daily", "all"):
        finish_request(sb, req["id"], "failed", f"Unsupported scope={scope}")
        return

    api = login_garmin(sb, user_id, cred["email"], cred["password"])
    date_from = req["date_from"]
    date_to = req["date_to"]

    act_counts = {"fetched": 0, "synced": 0, "skipped": 0}
    day_counts = {"fetched": 0, "synced": 0, "skipped": 0}
    step_errors: list[str] = []

    if scope in ("activities", "all"):
        act_counts = sync_activities_for_range(sb, api, user_id, date_from, date_to, req["id"])
        sb.rpc("link_garmin_activity_training_log", {"p_user_id": user_id}).execute()

    if scope in ("daily", "all"):
        day_counts = sync_daily_for_range(sb, api, user_id, date_from, date_to, req["id"])

    status, error = resolve_request_status(
        scope=scope,
        activities_fetched=act_counts["fetched"],
        activities_synced=act_counts["synced"],
        activities_skipped=act_counts["skipped"],
        daily_fetched=day_counts["fetched"],
        daily_synced=day_counts["synced"],
        daily_skipped=day_counts["skipped"],
        step_errors=step_errors,
    )
    progress = {
        "activities": act_counts,
        "daily": day_counts,
    }
    finish_request(sb, req["id"], status, error, progress)


def main() -> None:
    sb = create_client(_env("SUPABASE_URL"), _env("SUPABASE_SERVICE_ROLE_KEY"))
    users = {u["supabase_user_id"]: u for u in load_users()}
    request_id = os.environ.get("REQUEST_ID", "").strip() or None

    prepare_queue(sb)

    while True:
        req = claim_request(sb, request_id)
        if not req:
            break
        try:
            process_request(sb, req, users)
        except Exception as exc:  # noqa: BLE001
            finish_request(sb, req["id"], "failed", str(exc))
        if request_id:
            break


if __name__ == "__main__":
    main()
