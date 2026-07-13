#!/usr/bin/env python3
"""Garmin Connect 全量サンプルエクスポート（調査 Phase 0 用）

FIT ORIGINAL（zip）+ アクティビティ/日次 API レスポンスをすべてローカル保存する。
Issue #15 / docs/garmin-api-sync-investigation.md 参照。

使い方:
  python3 -m venv .venv && source .venv/bin/activate
  pip install garminconnect curl_cffi
  export GARMIN_EMAIL='your@email.com'
  export GARMIN_PASSWORD='your-password'
  python scripts/garmin_export_samples.py

⚠️ 出力には個人の健康データが含まれる。Git にコミットしないこと。
"""

from __future__ import annotations

import json
import os
import sys
import zipfile
from datetime import date, timedelta
from io import BytesIO
from pathlib import Path
from typing import Any, Callable

try:
    from garminconnect import Garmin
except ImportError:
    print("garminconnect が未インストールです: pip install garminconnect curl_cffi", file=sys.stderr)
    sys.exit(1)


# --- アクティビティ API（読み取り系すべて） ---
ACTIVITY_FETCHERS: dict[str, Callable[[Garmin, str], Any]] = {}

# --- 日次 API（読み取り系すべて） ---
DAILY_FETCHERS: dict[str, Callable[[Garmin, str], Any]] = {}


def _register_fetchers() -> None:
    """遅延登録: Garmin クラスのメソッド名をキーにする。"""
    global ACTIVITY_FETCHERS, DAILY_FETCHERS
    if ACTIVITY_FETCHERS:
        return

    ACTIVITY_FETCHERS = {
        "get_activity": lambda api, aid: api.get_activity(aid),
        "get_activity_details": lambda api, aid: api.get_activity_details(aid),
        "get_activity_splits": lambda api, aid: api.get_activity_splits(aid),
        "get_activity_typed_splits": lambda api, aid: api.get_activity_typed_splits(aid),
        "get_activity_split_summaries": lambda api, aid: api.get_activity_split_summaries(aid),
        "get_activity_weather": lambda api, aid: api.get_activity_weather(aid),
        "get_activity_hr_in_timezones": lambda api, aid: api.get_activity_hr_in_timezones(aid),
        "get_activity_power_in_timezones": lambda api, aid: api.get_activity_power_in_timezones(aid),
        "get_activity_exercise_sets": lambda api, aid: api.get_activity_exercise_sets(aid),
        "get_activity_gear": lambda api, aid: api.get_activity_gear(aid),
    }

    DAILY_FETCHERS = {
        "get_stats": lambda api, d: api.get_stats(d),
        "get_user_summary": lambda api, d: api.get_user_summary(d),
        "get_stats_and_body": lambda api, d: api.get_stats_and_body(d),
        "get_sleep_data": lambda api, d: api.get_sleep_data(d),
        "get_hrv_data": lambda api, d: api.get_hrv_data(d),
        "get_training_readiness": lambda api, d: api.get_training_readiness(d),
        "get_training_status": lambda api, d: api.get_training_status(d),
        "get_body_battery": lambda api, d: api.get_body_battery(d),
        "get_body_battery_events": lambda api, d: api.get_body_battery_events(d),
        "get_stress_data": lambda api, d: api.get_stress_data(d),
        "get_all_day_stress": lambda api, d: api.get_all_day_stress(d),
        "get_heart_rates": lambda api, d: api.get_heart_rates(d),
        "get_resting_heart_rate": lambda api, d: api.get_resting_heart_rate(d),
        "get_steps_data": lambda api, d: api.get_steps_data(d),
        "get_respiration_data": lambda api, d: api.get_respiration_data(d),
        "get_spo2_data": lambda api, d: api.get_spo2_data(d),
        "get_max_metrics": lambda api, d: api.get_max_metrics(d),
        "get_intensity_minutes_data": lambda api, d: api.get_intensity_minutes_data(d),
        "get_running_tolerance": lambda api, d: api.get_running_tolerance(d),
        "get_body_composition": lambda api, d: api.get_body_composition(d),
        "get_floors": lambda api, d: api.get_floors(d),
        "get_daily_steps": lambda api, d: api.get_daily_steps(d, d),
        "get_lifestyle_logging_data": lambda api, d: api.get_lifestyle_logging_data(d),
    }


def _env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        print(f"環境変数 {name} を設定してください", file=sys.stderr)
        sys.exit(1)
    return value


def _safe_json(obj: Any) -> Any:
    if isinstance(obj, bytes):
        return {"_type": "bytes", "length": len(obj)}
    if isinstance(obj, dict):
        return {k: _safe_json(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_safe_json(v) for v in obj]
    return obj


def _write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        json.dump(_safe_json(payload), f, ensure_ascii=False, indent=2)
    print(f"  wrote {path}")


def _try_call(fn: Callable[..., Any], *args: Any) -> Any:
    try:
        return fn(*args)
    except Exception as exc:  # noqa: BLE001 — 調査用
        return {"_error": type(exc).__name__, "message": str(exc)}


def _download_fit(api: Garmin, activity_id: str, out_dir: Path) -> dict[str, Any]:
    """FIT ORIGINAL（zip）をダウンロードし、zip 内ファイル一覧を返す。"""
    result: dict[str, Any] = {"activity_id": activity_id}
    try:
        raw = api.download_activity(
            activity_id,
            dl_fmt=Garmin.ActivityDownloadFormat.ORIGINAL,
        )
        zip_path = out_dir / f"{activity_id}.zip"
        zip_path.write_bytes(raw)
        result["zip_path"] = str(zip_path)
        result["zip_bytes"] = len(raw)

        with zipfile.ZipFile(BytesIO(raw)) as zf:
            result["zip_contents"] = zf.namelist()
            for name in zf.namelist():
                if name.lower().endswith(".fit"):
                    fit_bytes = zf.read(name)
                    fit_path = out_dir / f"{activity_id}.fit"
                    fit_path.write_bytes(fit_bytes)
                    result["fit_path"] = str(fit_path)
                    result["fit_bytes"] = len(fit_bytes)
                    break
        print(f"  FIT zip: {zip_path} ({len(raw)} bytes)")
    except Exception as exc:  # noqa: BLE001
        result["_error"] = {"type": type(exc).__name__, "message": str(exc)}
        print(f"  FIT download failed: {exc}")
    return result


def _export_activity(api: Garmin, act: dict[str, Any], out_dir: Path) -> None:
    aid = str(act.get("activityId", ""))
    if not aid:
        return

    type_key = (act.get("activityType") or {}).get("typeKey", "unknown")
    act_dir = out_dir / "activities" / f"{aid}_{type_key}"
    act_dir.mkdir(parents=True, exist_ok=True)

    print(f"\nアクティビティ {aid} ({type_key})")

    responses: dict[str, Any] = {"list_summary": act}
    for name, fetcher in ACTIVITY_FETCHERS.items():
        print(f"  {name}...")
        responses[name] = _try_call(fetcher, api, aid)

    _write_json(act_dir / "api_responses.json", responses)

    fit_meta = _download_fit(api, aid, act_dir)
    _write_json(act_dir / "fit_download.json", fit_meta)


def main() -> None:
    _register_fetchers()

    email = _env("GARMIN_EMAIL")
    password = _env("GARMIN_PASSWORD")
    lookback_days = int(os.environ.get("GARMIN_LOOKBACK_DAYS", "14"))

    out_dir = Path(os.environ.get("GARMIN_EXPORT_DIR", "garmin_export_samples"))
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"出力先: {out_dir.resolve()}")
    print("Garmin Connect にログイン中...")

    api = Garmin(email, password)
    api.login()
    print("ログイン成功")

    today = date.today()
    start = (today - timedelta(days=lookback_days)).isoformat()
    end = today.isoformat()

    print(f"\nアクティビティ一覧: {start} .. {end}")
    activities = api.get_activities_by_date(start, end)
    _write_json(out_dir / "activities_by_date.json", activities)
    print(f"  {len(activities)} 件")

    for act in activities:
        _export_activity(api, act, out_dir)

    print(f"\n日次データ（直近 {min(lookback_days, 7)} 日）")
    daily_dir = out_dir / "daily"
    daily_dir.mkdir(parents=True, exist_ok=True)

    for offset in range(min(lookback_days, 7)):
        d = (today - timedelta(days=offset)).isoformat()
        print(f"  {d}")
        day_responses: dict[str, Any] = {}
        for name, fetcher in DAILY_FETCHERS.items():
            day_responses[name] = _try_call(fetcher, api, d)
        _write_json(daily_dir / f"{d}.json", day_responses)

    manifest = {
        "exported_at": today.isoformat(),
        "date_range": {"start": start, "end": end},
        "activity_count": len(activities),
        "activity_fetchers": list(ACTIVITY_FETCHERS.keys()),
        "daily_fetchers": list(DAILY_FETCHERS.keys()),
        "mfa": "disabled (assumed)",
        "note": "FIT zip in activities/{id}_{type}/. Compare with Supabase training_log.",
    }
    _write_json(out_dir / "manifest.json", manifest)

    print("\n完了。")
    print("  1. activities/*/api_responses.json — 全 API レスポンス")
    print("  2. activities/*/*.zip / *.fit — FIT 原データ")
    print("  3. daily/*.json — 日次全 API レスポンス")


if __name__ == "__main__":
    main()
