#!/usr/bin/env python3
"""Garmin Sync Job — garmin_sync_request キューを処理する。

Phase 1: scope=activities のみ。docs/garmin-sync-ops.md 参照。

環境変数:
  SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
  GARMIN_SYNC_USERS — JSON [{supabase_user_id, email, password}]
  REQUEST_ID — 省略時は pending 全件（古い順）
  JSON_INLINE_MAX_BYTES — デフォルト 524288 (512KB)
"""

from __future__ import annotations

import json
import os
import sys
import zipfile
from datetime import UTC, datetime
from io import BytesIO
from typing import Any

try:
    from garminconnect import Garmin
    from supabase import create_client
except ImportError:
    print("pip install garminconnect curl_cffi fitparse supabase", file=sys.stderr)
    sys.exit(1)

JSON_INLINE_MAX = int(os.environ.get("JSON_INLINE_MAX_BYTES", "524288"))
STALE_MINUTES = 30

ACTIVITY_FETCHERS = [
    "get_activity",
    "get_activity_details",
    "get_activity_splits",
    "get_activity_typed_splits",
    "get_activity_split_summaries",
    "get_activity_weather",
    "get_activity_hr_in_timezones",
    "get_activity_power_in_timezones",
    "get_activity_exercise_sets",
    "get_activity_gear",
]


def _env(name: str) -> str:
    v = os.environ.get(name, "").strip()
    if not v:
        raise SystemExit(f"Missing env: {name}")
    return v


def _json_safe(obj: Any) -> Any:
    if isinstance(obj, bytes):
        return {"_type": "bytes", "length": len(obj)}
    if isinstance(obj, datetime):
        return obj.isoformat()
    if isinstance(obj, dict):
        return {k: _json_safe(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_json_safe(v) for v in obj]
    return obj


def _try_call(fn: Any, *args: Any) -> Any:
    try:
        return _json_safe(fn(*args))
    except Exception as exc:  # noqa: BLE001
        return {"_error": type(exc).__name__, "message": str(exc)}


def _fit_to_json(fit_bytes: bytes) -> dict[str, Any]:
    try:
        import fitparse
    except ImportError:
        return {"_error": "fitparse not installed"}

    messages = []
    for msg in fitparse.FitFile(BytesIO(fit_bytes)).get_messages():
        messages.append({
            "name": msg.name,
            "fields": {f.name: _json_safe(f.value) for f in msg.fields},
        })
    return {"messages": messages, "message_count": len(messages)}


def load_users() -> list[dict[str, str]]:
    return json.loads(_env("GARMIN_SYNC_USERS"))


def login_garmin(sb: Any, user_id: str, email: str, password: str) -> Garmin:
    api = Garmin(email, password)
    row = (
        sb.table("garmin_oauth_tokens")
        .select("token_store")
        .eq("user_id", user_id)
        .maybe_single()
        .execute()
    )
    if row.data and row.data.get("token_store"):
        try:
            api.loads(json.dumps(row.data["token_store"]))
        except Exception:
            pass
    api.login()
    sb.table("garmin_oauth_tokens").upsert({
        "user_id": user_id,
        "token_store": json.loads(api.dumps()),
        "updated_at": datetime.now(UTC).isoformat(),
    }).execute()
    return api


def reset_stale(sb: Any) -> None:
    sb.rpc("reset_stale_garmin_sync_requests", {"stale_minutes": STALE_MINUTES}).execute()


def claim_request(sb: Any, request_id: str | None) -> dict[str, Any] | None:
    q = sb.table("garmin_sync_request").select("*").eq("status", "pending").order("requested_at")
    if request_id:
        q = q.eq("id", request_id)
    rows = q.limit(1).execute().data or []
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
    if not updated.data:
        return None
    return updated.data[0]


def finish_request(sb: Any, req_id: str, status: str, error: str | None = None) -> None:
    payload: dict[str, Any] = {
        "status": status,
        "completed_at": datetime.now(UTC).isoformat(),
    }
    if error:
        payload["error_message"] = error
    sb.table("garmin_sync_request").update(payload).eq("id", req_id).execute()


def already_synced(sb: Any, user_id: str, activity_id: int) -> bool:
    row = (
        sb.table("garmin_activity_archive")
        .select("sync_status")
        .eq("user_id", user_id)
        .eq("garmin_activity_id", activity_id)
        .maybe_single()
        .execute()
    )
    return bool(row.data and row.data.get("sync_status") == "complete")


def upload_json(sb: Any, bucket: str, path: str, payload: dict[str, Any]) -> str:
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    sb.storage.from_(bucket).upload(path, data, {"content-type": "application/json", "upsert": "true"})
    return path


def upload_fit_zip(sb: Any, user_id: str, activity_id: int, raw: bytes) -> str:
    path = f"{user_id}/{activity_id}.zip"
    sb.storage.from_("garmin-fit").upload(
        path, raw, {"content-type": "application/zip", "upsert": "true"}
    )
    return path


def maybe_inline_or_storage(
    sb: Any, user_id: str, kind: str, activity_id: int, payload: dict[str, Any]
) -> tuple[dict[str, Any], str | None]:
    encoded = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    if len(encoded) <= JSON_INLINE_MAX:
        return payload, None
    path = f"{user_id}/activities/{activity_id}_{kind}.json"
    upload_json(sb, "garmin-json", path, payload)
    return {"_storage_path": path, "_bytes": len(encoded)}, path


def sync_activity(
    sb: Any, api: Garmin, user_id: str, act: dict[str, Any], request_id: str
) -> None:
    aid = act.get("activityId")
    if not aid or already_synced(sb, user_id, int(aid)):
        return

    aid_str = str(aid)
    api_responses: dict[str, Any] = {"list_summary": act}
    errors: list[dict[str, str]] = []

    for name in ACTIVITY_FETCHERS:
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
                    fit_parsed = _fit_to_json(zf.read(name))
                    break
    except Exception as exc:  # noqa: BLE001
        errors.append({"step": "fit_download", "error": str(exc)})

    summary = api_responses.get("get_activity") or act
    if isinstance(summary, dict) and "_error" in summary:
        summary = act

    inline_api, api_path = maybe_inline_or_storage(sb, user_id, "api", int(aid), api_responses)
    inline_fit, fit_path = maybe_inline_or_storage(sb, user_id, "fit_parsed", int(aid), fit_parsed)

    sync_status = "complete" if not errors else "partial"
    sb.table("garmin_activity_archive").upsert({
        "user_id": user_id,
        "garmin_activity_id": int(aid),
        "activity_type_key": (act.get("activityType") or {}).get("typeKey"),
        "activity_name": act.get("activityName"),
        "start_time_local": act.get("startTimeLocal"),
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


def process_request(sb: Any, req: dict[str, Any], users_by_id: dict[str, dict[str, str]]) -> None:
    user_id = req["user_id"]
    cred = users_by_id.get(user_id)
    if not cred:
        finish_request(sb, req["id"], "failed", f"No credentials for user {user_id}")
        return

    if req["scope"] != "activities":
        finish_request(sb, req["id"], "failed", f"Phase 1: scope={req['scope']} not supported")
        return

    api = login_garmin(sb, user_id, cred["email"], cred["password"])
    activities = api.get_activities_by_date(req["date_from"], req["date_to"])
    for act in activities:
        sync_activity(sb, api, user_id, act, req["id"])

    sb.rpc("link_garmin_activity_training_log", {"p_user_id": user_id}).execute()
    finish_request(sb, req["id"], "complete")


def main() -> None:
    sb = create_client(_env("SUPABASE_URL"), _env("SUPABASE_SERVICE_ROLE_KEY"))
    users = {u["supabase_user_id"]: u for u in load_users()}
    request_id = os.environ.get("REQUEST_ID", "").strip() or None

    reset_stale(sb)

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
