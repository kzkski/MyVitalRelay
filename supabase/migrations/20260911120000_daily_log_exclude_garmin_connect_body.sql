-- Issue #38: daily_log の体組成集計から Garmin Connect Mobile を除外する。
-- 判定キーは source_bundle_id（source_name の部分一致は使わない）。
-- Eufy / Omron は残す。同一 measured_at の weight + fat ペアリングは維持。
-- 列構成は変更しない（CREATE OR REPLACE 互換）。

CREATE OR REPLACE VIEW public.daily_log
WITH (security_invoker = true)
AS
WITH pfc AS (
  SELECT
    food_log.user_id,
    food_log.date,
    sum(food_log.protein_g) AS protein_g,
    sum(food_log.fat_g) AS fat_g,
    sum(food_log.carbs_g) AS carbs_g
  FROM food_log
  GROUP BY food_log.user_id, food_log.date
),
first_ts AS (
  SELECT
    body_composition_sample.user_id,
    body_composition_sample.date,
    min(body_composition_sample.measured_at) AS first_measured_at
  FROM body_composition_sample
  WHERE body_composition_sample.source_bundle_id IS DISTINCT FROM 'com.garmin.connect.mobile'
  GROUP BY body_composition_sample.user_id, body_composition_sample.date
),
first_body AS (
  SELECT
    f.user_id,
    f.date,
    max(b.weight_kg) AS weight_kg,
    max(b.body_fat_pct) AS body_fat_pct
  FROM first_ts f
  JOIN body_composition_sample b
    ON b.user_id = f.user_id
   AND b.date = f.date
   AND b.measured_at = f.first_measured_at
   AND b.source_bundle_id IS DISTINCT FROM 'com.garmin.connect.mobile'
  GROUP BY f.user_id, f.date
),
sleep_dedup AS (
  SELECT DISTINCT
    sleep_segment.user_id,
    sleep_segment.start_time,
    sleep_segment.end_time,
    sleep_segment.stage,
    sleep_segment.duration_sec
  FROM sleep_segment
),
sleep_nightly AS (
  SELECT
    sleep_dedup.user_id,
    CASE
      WHEN EXTRACT(hour FROM (sleep_dedup.start_time AT TIME ZONE 'Asia/Tokyo'::text)) < 15::numeric
        THEN (sleep_dedup.start_time AT TIME ZONE 'Asia/Tokyo'::text)::date
      ELSE ((sleep_dedup.start_time AT TIME ZONE 'Asia/Tokyo'::text)::date + '1 day'::interval)::date
    END AS date,
    sum(sleep_dedup.duration_sec) AS sleep_seconds,
    sum(
      CASE
        WHEN sleep_dedup.stage = 'deep'::text THEN sleep_dedup.duration_sec
        ELSE 0
      END
    ) AS deep_sleep_seconds,
    sum(
      CASE
        WHEN sleep_dedup.stage = 'rem'::text THEN sleep_dedup.duration_sec
        ELSE 0
      END
    ) AS rem_sleep_seconds
  FROM sleep_dedup
  GROUP BY
    sleep_dedup.user_id,
    CASE
      WHEN EXTRACT(hour FROM (sleep_dedup.start_time AT TIME ZONE 'Asia/Tokyo'::text)) < 15::numeric
        THEN (sleep_dedup.start_time AT TIME ZONE 'Asia/Tokyo'::text)::date
      ELSE ((sleep_dedup.start_time AT TIME ZONE 'Asia/Tokyo'::text)::date + '1 day'::interval)::date
    END
  HAVING sum(sleep_dedup.duration_sec) > 3600
),
all_dates AS (
  SELECT pfc.user_id, pfc.date FROM pfc
  UNION
  SELECT first_body.user_id, first_body.date FROM first_body
  UNION
  SELECT sleep_nightly.user_id, sleep_nightly.date FROM sleep_nightly
  UNION
  SELECT daily_activity_summary.user_id, daily_activity_summary.date
  FROM daily_activity_summary
)
SELECT
  ad.date,
  ad.user_id,
  fb.weight_kg,
  fb.body_fat_pct,
  sn.sleep_seconds,
  round(sn.sleep_seconds::numeric / 3600.0, 2) AS sleep_hours_decimal,
  sn.deep_sleep_seconds,
  sn.rem_sleep_seconds,
  das.active_calories_kcal AS calories_burned,
  das.basal_calories_kcal,
  p.protein_g,
  p.fat_g,
  p.carbs_g,
  das.notes
FROM all_dates ad
LEFT JOIN pfc p ON p.user_id = ad.user_id AND p.date = ad.date
LEFT JOIN first_body fb ON fb.user_id = ad.user_id AND fb.date = ad.date
LEFT JOIN sleep_nightly sn ON sn.user_id = ad.user_id AND sn.date = ad.date
LEFT JOIN daily_activity_summary das ON das.user_id = ad.user_id AND das.date = ad.date
ORDER BY ad.date;

COMMENT ON VIEW public.daily_log IS
  '日次集計ビュー（food_log / body_composition / sleep / activity）。体組成は com.garmin.connect.mobile を除外した最初の測定。security_invoker=true。Issue MyVitalRelay#38';

REVOKE ALL ON public.daily_log FROM anon;
REVOKE ALL ON public.daily_log FROM PUBLIC;
REVOKE ALL ON public.daily_log FROM authenticated;
GRANT SELECT ON public.daily_log TO authenticated;
