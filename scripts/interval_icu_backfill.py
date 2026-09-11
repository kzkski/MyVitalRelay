#!/usr/bin/env python3
"""Intervals.icu wellness 全履歴バックフィル（初回ワンショット用）。

body_composition_sample を走査し、日次の最初の weight / bodyFat を wellness-bulk で PUSH。
キューは経由しない。GitHub Actions「Interval.icu Backfill」から実行する想定。

使い方:
  export SUPABASE_URL=...
  export SUPABASE_SERVICE_ROLE_KEY=...
  export INTERVAL_ICU_SYNC_USERS='[{"supabase_user_id":"...","api_key":"..."}]'
  # 省略可（単一ユーザー想定時は SYNC_USERS の先頭を使う）
  export INTERVAL_ICU_BACKFILL_USER_ID=...
  PYTHONPATH=scripts python scripts/interval_icu_backfill.py
"""

from __future__ import annotations

import json
import os
import sys
from datetime import UTC, datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

try:
    import requests
    from supabase import create_client
except ImportError:
    print("pip install supabase requests", file=sys.stderr)
    sys.exit(1)

from interval_icu_backfill_lib import (
    build_wellness_bulk_item,
    group_samples_by_date,
    pick_daily_metrics,
)


def _env(name: str) -> str:
    v = os.environ.get(name, "").strip()
    if not v:
        raise SystemExit(f"Missing env: {name}")
    return v


def _load_users() -> list[dict]:
    raw = _env("INTERVAL_ICU_SYNC_USERS")
    users = json.loads(raw)
    if not isinstance(users, list) or not users:
        raise SystemExit("INTERVAL_ICU_SYNC_USERS must be a non-empty JSON array")
    return users


def _resolve_user(users: list[dict]) -> dict:
    user_id = os.environ.get("INTERVAL_ICU_BACKFILL_USER_ID", "").strip()
    if user_id:
        for user in users:
            if user.get("supabase_user_id") == user_id:
                return user
        raise SystemExit(f"No INTERVAL_ICU_SYNC_USERS entry for {user_id}")
    if len(users) == 1:
        return users[0]
    raise SystemExit("Set INTERVAL_ICU_BACKFILL_USER_ID when multiple users are configured")


def _athlete_id(user: dict) -> str:
    aid = str(user.get("athlete_id") or "").strip()
    return aid or "0"


def main() -> None:
    sb = create_client(_env("SUPABASE_URL"), _env("SUPABASE_SERVICE_ROLE_KEY"))
    user = _resolve_user(_load_users())
    supabase_user_id = user["supabase_user_id"]
    api_key = user["api_key"]
    athlete_id = _athlete_id(user)

    print(f"Backfill user={supabase_user_id} athlete_id={athlete_id}")

    resp = (
        sb.table("body_composition_sample")
        .select("date,measured_at,weight_kg,body_fat_pct,source_bundle_id")
        .eq("user_id", supabase_user_id)
        .order("date")
        .execute()
    )
    rows = resp.data or []
    grouped = group_samples_by_date(rows)

    items: list[dict] = []
    for day in sorted(grouped.keys()):
        metrics = pick_daily_metrics(grouped[day])
        item = build_wellness_bulk_item(day, metrics)
        if item is not None:
            items.append(item)

    print(f"Days with metrics: {len(items)} (raw rows={len(rows)})")
    if not items:
        print("Nothing to push.")
        return

    url = f"https://intervals.icu/api/v1/athlete/{athlete_id}/wellness-bulk"
    # バックフィルは過去日中心。localDate は付けず settings 現在体重を汚染しない。
    put = requests.put(
        url,
        auth=("API_KEY", api_key),
        headers={"Content-Type": "application/json", "Accept": "application/json"},
        json=items,
        timeout=120,
    )
    if not put.ok:
        raise SystemExit(f"wellness-bulk failed HTTP {put.status_code}: {put.text[:500]}")

    print(f"Done: pushed={len(items)} at {datetime.now(UTC).isoformat()}")
    print("Note: settings current weight was NOT updated (no localDate on bulk).")


if __name__ == "__main__":
    main()
