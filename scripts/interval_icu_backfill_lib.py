"""Intervals.icu backfill helpers (Issue #24).

Daily aggregation mirrors supabase/functions/interval-icu-sync/lib.ts.
"""

from __future__ import annotations

from typing import Any


def round1(value: float) -> float:
    return round(value * 10) / 10


DENIED_BODY_SOURCE_BUNDLE_IDS = frozenset({"com.garmin.connect.mobile"})


def is_denied_body_source(bundle_id: Any) -> bool:
    return bundle_id is not None and str(bundle_id) in DENIED_BODY_SOURCE_BUNDLE_IDS


def pick_daily_metrics(samples: list[dict[str, Any]]) -> dict[str, float]:
    """Pick earliest weight_kg and body_fat_pct independently by measured_at.

    Garmin Connect Mobile samples are skipped (Issue #38). Missing bundle id is allowed.
    """
    first_weight: tuple[str, float] | None = None
    first_bf: tuple[str, float] | None = None

    for sample in samples:
        if is_denied_body_source(sample.get("source_bundle_id")):
            continue
        measured_at = str(sample.get("measured_at") or "")
        weight = sample.get("weight_kg")
        body_fat = sample.get("body_fat_pct")

        if weight is not None:
            try:
                w = float(weight)
            except (TypeError, ValueError):
                w = None
            if w is not None and (first_weight is None or measured_at < first_weight[0]):
                first_weight = (measured_at, w)

        if body_fat is not None:
            try:
                bf = float(body_fat)
            except (TypeError, ValueError):
                bf = None
            if bf is not None and (first_bf is None or measured_at < first_bf[0]):
                first_bf = (measured_at, bf)

    out: dict[str, float] = {}
    if first_weight is not None:
        out["weight"] = round1(first_weight[1])
    if first_bf is not None:
        out["bodyFat"] = round1(first_bf[1])
    return out


def build_wellness_bulk_item(day: str, metrics: dict[str, float]) -> dict[str, Any] | None:
    if not metrics:
        return None
    item: dict[str, Any] = {"id": day}
    item.update(metrics)
    return item


def group_samples_by_date(rows: list[dict[str, Any]]) -> dict[str, list[dict[str, Any]]]:
    grouped: dict[str, list[dict[str, Any]]] = {}
    for row in rows:
        day = str(row.get("date") or "")
        if not day:
            continue
        grouped.setdefault(day, []).append(row)
    return grouped
