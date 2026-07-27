"""Tests for interval_icu_backfill_lib."""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

from interval_icu_backfill_lib import (  # noqa: E402
    build_wellness_bulk_item,
    group_samples_by_date,
    pick_daily_metrics,
    round1,
)


def test_round1() -> None:
    assert round1(70.55) == 70.6
    assert round1(15.04) == 15.0


def test_pick_daily_metrics_independent_earliest() -> None:
    metrics = pick_daily_metrics(
        [
            {"measured_at": "2026-07-27T01:00:00Z", "weight_kg": 70.0, "body_fat_pct": None},
            {"measured_at": "2026-07-27T08:00:00Z", "weight_kg": None, "body_fat_pct": 15.4},
            {"measured_at": "2026-07-27T03:00:00Z", "weight_kg": 70.55, "body_fat_pct": 14.0},
        ]
    )
    assert metrics == {"weight": 70.0, "bodyFat": 14.0}


def test_pick_daily_metrics_empty() -> None:
    assert pick_daily_metrics([]) == {}


def test_build_wellness_bulk_item() -> None:
    assert build_wellness_bulk_item("2026-07-27", {}) is None
    assert build_wellness_bulk_item("2026-07-27", {"weight": 70.0}) == {
        "id": "2026-07-27",
        "weight": 70.0,
    }


def test_group_samples_by_date() -> None:
    grouped = group_samples_by_date(
        [
            {"date": "2026-07-27", "weight_kg": 70},
            {"date": "2026-07-26", "weight_kg": 71},
            {"date": "2026-07-27", "body_fat_pct": 15},
        ]
    )
    assert set(grouped.keys()) == {"2026-07-26", "2026-07-27"}
    assert len(grouped["2026-07-27"]) == 2
