#!/usr/bin/env python3
"""Garmin Connect API サンプルエクスポート（調査 Phase 0 用）

Issue #15 調査: HealthKit 同期済みデータとの差分確認のため、
Garmin API から生 JSON を取得してローカルに保存する。

使い方:
  python3 -m venv .venv && source .venv/bin/activate
  pip install garminconnect curl_cffi
  export GARMIN_EMAIL='your@email.com'
  export GARMIN_PASSWORD='your-password'
  python scripts/garmin_export_samples.py

初回ログインで MFA が求められた場合、プロンプトが表示される。
トークンは ~/.garminconnect/garmin_tokens.json に保存される。

⚠️ 出力 JSON には個人の健康データが含まれる。Git にコミットしないこと。
"""

from __future__ import annotations

import json
import os
import sys
from datetime import date, timedelta
from pathlib import Path
from typing import Any

try:
    from garminconnect import Garmin
except ImportError:
    print("garminconnect が未インストールです: pip install garminconnect curl_cffi", file=sys.stderr)
    sys.exit(1)


def _env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        print(f"環境変数 {name} を設定してください", file=sys.stderr)
        sys.exit(1)
    return value


def _safe_json(obj: Any) -> Any:
    """bytes 等を JSON シリアライズ可能にする。"""
    if isinstance(obj, bytes):
        return {"_type": "bytes", "length": len(obj)}
    if isinstance(obj, dict):
        return {k: _safe_json(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_safe_json(v) for v in obj]
    return obj


def _write(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        json.dump(_safe_json(payload), f, ensure_ascii=False, indent=2)
    print(f"  wrote {path}")


def _pick_strength_activity(activities: list[dict[str, Any]]) -> dict[str, Any] | None:
    for act in activities:
        type_key = (act.get("activityType") or {}).get("typeKey", "")
        if "strength" in type_key.lower() or "training" in type_key.lower():
            return act
    return None


def main() -> None:
    email = _env("GARMIN_EMAIL")
    password = _env("GARMIN_PASSWORD")

    out_dir = Path(os.environ.get("GARMIN_EXPORT_DIR", "garmin_export_samples"))
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"出力先: {out_dir.resolve()}")
    print("Garmin Connect にログイン中...")

    api = Garmin(email, password)
    api.login()
    print("ログイン成功")

    today = date.today()
    start = (today - timedelta(days=14)).isoformat()
    end = today.isoformat()

    print(f"アクティビティ取得: {start} .. {end}")
    activities = api.get_activities_by_date(start, end)
    _write(out_dir / "activities_by_date.json", activities)

    if not activities:
        print("期間内にアクティビティがありません")
        return

    # 種目別に代表1件ずつ詳細取得
    by_type: dict[str, dict[str, Any]] = {}
    for act in activities:
        key = (act.get("activityType") or {}).get("typeKey", "unknown")
        if key not in by_type:
            by_type[key] = act

    detail_bundle: dict[str, Any] = {}
    for type_key, act in by_type.items():
        aid = act.get("activityId")
        if not aid:
            continue
        print(f"詳細取得: {type_key} activityId={aid}")
        detail_bundle[type_key] = {
            "summary": act,
            "get_activity": api.get_activity(str(aid)),
            "splits": _try_call(api.get_activity_splits, str(aid)),
            "split_summaries": _try_call(api.get_activity_split_summaries, str(aid)),
            "hr_zones": _try_call(api.get_activity_hr_in_timezones, str(aid)),
            "power_zones": _try_call(api.get_activity_power_in_timezones, str(aid)),
            "exercise_sets": _try_call(api.get_activity_exercise_sets, aid),
        }

    _write(out_dir / "activity_details_by_type.json", detail_bundle)

    strength = _pick_strength_activity(activities)
    if strength:
        sid = strength["activityId"]
        print(f"筋トレ exercise_sets 重点取得: activityId={sid}")
        _write(out_dir / "strength_exercise_sets.json", api.get_activity_exercise_sets(sid))

    # 日次ウェルネス（直近3日）
    wellness: dict[str, Any] = {}
    for offset in range(3):
        d = (today - timedelta(days=offset)).isoformat()
        print(f"日次データ: {d}")
        wellness[d] = {
            "stats": _try_call(api.get_stats, d),
            "hrv": _try_call(api.get_hrv_data, d),
            "training_readiness": _try_call(api.get_training_readiness, d),
            "training_status": _try_call(api.get_training_status, d),
            "body_battery": _try_call(api.get_body_battery, d),
            "stress": _try_call(api.get_stress_data, d),
            "sleep": _try_call(api.get_sleep_data, d),
        }
    _write(out_dir / "daily_wellness.json", wellness)

    # エクスポート manifest
    manifest = {
        "exported_at": today.isoformat(),
        "date_range": {"start": start, "end": end},
        "activity_count": len(activities),
        "activity_types": list(by_type.keys()),
        "files": [
            "activities_by_date.json",
            "activity_details_by_type.json",
            "daily_wellness.json",
        ],
        "note": "Compare startTimeLocal/duration with Supabase training_log rows (data_source=garmin)",
    }
    _write(out_dir / "manifest.json", manifest)

    print("\n完了。Supabase training_log と突合してください。")
    print("  SELECT start_time, end_time, workout_type, distance_km, avg_hr, cadence, power_watts")
    print("  FROM training_log WHERE data_source = 'garmin' ORDER BY start_time DESC LIMIT 20;")


def _try_call(fn: Any, *args: Any) -> Any:
    try:
        return fn(*args)
    except Exception as exc:  # noqa: BLE001 — 調査用スクリプト
        return {"_error": type(exc).__name__, "message": str(exc)}


if __name__ == "__main__":
    main()
