#!/usr/bin/env python3
"""Garmin 過去データバックフィル — garmin_sync_request を chunk 単位で投入。

Phase 2: デフォルト 90 日を 14 日 chunk でキュー投入。Sync Job が順次処理する。

使い方:
  export SUPABASE_URL=...
  export SUPABASE_SERVICE_ROLE_KEY=...
  export GARMIN_BACKFILL_USER_ID=77ea5bd6-...  # auth.users uuid
  python scripts/garmin_backfill.py

  # オプション
  export GARMIN_BACKFILL_DAYS=90
  export GARMIN_BACKFILL_CHUNK_DAYS=14
  export GARMIN_BACKFILL_SCOPE=all   # activities | daily | all
"""

from __future__ import annotations

import os
import sys
from datetime import UTC, date, datetime, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

try:
    from supabase import create_client
except ImportError:
    print("pip install supabase", file=sys.stderr)
    sys.exit(1)

from garmin_sync_lib import chunk_date_range


def _env(name: str) -> str:
    v = os.environ.get(name, "").strip()
    if not v:
        raise SystemExit(f"Missing env: {name}")
    return v


def main() -> None:
    sb = create_client(_env("SUPABASE_URL"), _env("SUPABASE_SERVICE_ROLE_KEY"))
    user_id = _env("GARMIN_BACKFILL_USER_ID")
    lookback_days = int(os.environ.get("GARMIN_BACKFILL_DAYS", "90"))
    chunk_days = int(os.environ.get("GARMIN_BACKFILL_CHUNK_DAYS", "14"))
    scope = os.environ.get("GARMIN_BACKFILL_SCOPE", "activities").strip()
    if scope not in ("activities", "daily", "all"):
        raise SystemExit(f"Invalid GARMIN_BACKFILL_SCOPE: {scope}")

    today = date.today()
    date_from = (today - timedelta(days=lookback_days)).isoformat()
    date_to = today.isoformat()
    chunks = chunk_date_range(date_from, date_to, chunk_days)

    print(f"Backfill: user={user_id} scope={scope} {date_from}..{date_to} ({len(chunks)} chunks)")

    inserted = 0
    skipped = 0
    for chunk_from, chunk_to in chunks:
        row = {
            "user_id": user_id,
            "scope": scope,
            "date_from": chunk_from,
            "date_to": chunk_to,
            "trigger_source": "manual",
        }
        try:
            sb.table("garmin_sync_request").insert(row).execute()
            inserted += 1
            print(f"  queued {chunk_from}..{chunk_to}")
        except Exception as exc:  # noqa: BLE001
            msg = str(exc).lower()
            if "23505" in msg or "duplicate" in msg or "unique constraint" in msg:
                skipped += 1
                print(f"  skip (pending exists) {chunk_from}..{chunk_to}")
            else:
                raise

    print(f"Done: inserted={inserted} skipped={skipped} at {datetime.now(UTC).isoformat()}")
    print("Run GitHub Actions「Garmin Sync」で処理開始。")


if __name__ == "__main__":
    main()
