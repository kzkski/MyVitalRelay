"""Garmin Connect API フェッチャー定義（sync job / export_samples 共通）。"""

from __future__ import annotations

from typing import Any, Callable

ACTIVITY_FETCHER_NAMES = [
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

DAILY_FETCHER_NAMES = [
    "get_stats",
    "get_user_summary",
    "get_stats_and_body",
    "get_sleep_data",
    "get_hrv_data",
    "get_training_readiness",
    "get_training_status",
    "get_body_battery",
    "get_body_battery_events",
    "get_stress_data",
    "get_all_day_stress",
    "get_heart_rates",
    "get_resting_heart_rate",
    "get_steps_data",
    "get_respiration_data",
    "get_spo2_data",
    "get_max_metrics",
    "get_intensity_minutes_data",
    "get_running_tolerance",
    "get_body_composition",
    "get_floors",
    "get_daily_steps",
    "get_lifestyle_logging_data",
]


def call_activity_fetcher(api: Any, name: str, activity_id: str) -> Any:
    fn = getattr(api, name, None)
    if fn is None:
        return {"_error": "MissingFetcher", "message": name}
    return fn(activity_id)


def call_daily_fetcher(api: Any, name: str, day: str) -> Any:
    if name == "get_daily_steps":
        return api.get_daily_steps(day, day)
    fn = getattr(api, name, None)
    if fn is None:
        return {"_error": "MissingFetcher", "message": name}
    return fn(day)


def activity_fetchers_for_export() -> dict[str, Callable[[Any, str], Any]]:
    return {name: (lambda api, aid, n=name: call_activity_fetcher(api, n, aid)) for name in ACTIVITY_FETCHER_NAMES}


def daily_fetchers_for_export() -> dict[str, Callable[[Any, str], Any]]:
    return {name: (lambda api, day, n=name: call_daily_fetcher(api, n, day)) for name in DAILY_FETCHER_NAMES}
