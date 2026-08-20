-- Issue #29: Garmin get_stats の日次カロリーを daily_activity_summary へ反映する。
-- スキーマ変更なし。active / basal を Garmin 値で埋め、合計は active + basal（≒ totalKilocalories）。
-- 日付: 活動日 D（archive.date）→ 格納日 D+1（既存の daily_log 規約）。

CREATE OR REPLACE FUNCTION apply_garmin_daily_calories_to_summary(
  p_user_id uuid,
  p_date_from date DEFAULT NULL,
  p_date_to date DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  affected integer;
BEGIN
  INSERT INTO daily_activity_summary AS s (
    user_id,
    date,
    active_calories_kcal,
    basal_calories_kcal,
    synced_at
  )
  SELECT
    d.user_id,
    (d.date + 1),
    (d.api_responses->'get_stats'->>'activeKilocalories')::numeric,
    (d.api_responses->'get_stats'->>'bmrKilocalories')::numeric,
    now()
  FROM garmin_daily_archive d
  WHERE d.user_id = p_user_id
    AND (p_date_from IS NULL OR d.date >= p_date_from)
    AND (p_date_to IS NULL OR d.date <= p_date_to)
    AND d.api_responses ? 'get_stats'
    AND jsonb_typeof(d.api_responses->'get_stats') = 'object'
    AND NOT (d.api_responses->'get_stats' ? '_error')
    AND (
      d.api_responses->'get_stats'->>'activeKilocalories' IS NOT NULL
      OR d.api_responses->'get_stats'->>'bmrKilocalories' IS NOT NULL
    )
  ON CONFLICT (user_id, date) DO UPDATE
  SET
    active_calories_kcal = EXCLUDED.active_calories_kcal,
    basal_calories_kcal = EXCLUDED.basal_calories_kcal,
    synced_at = EXCLUDED.synced_at
  WHERE s.active_calories_kcal IS DISTINCT FROM EXCLUDED.active_calories_kcal
     OR s.basal_calories_kcal IS DISTINCT FROM EXCLUDED.basal_calories_kcal;

  GET DIAGNOSTICS affected = ROW_COUNT;
  RETURN affected;
END;
$$;

REVOKE ALL ON FUNCTION apply_garmin_daily_calories_to_summary(uuid, date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION apply_garmin_daily_calories_to_summary(uuid, date, date) TO service_role;

-- バックフィル（全ユーザー・全 archive 日）
SELECT apply_garmin_daily_calories_to_summary(u, NULL, NULL)
FROM (SELECT DISTINCT user_id AS u FROM garmin_daily_archive) q;

-- Claude 向け: 日次カロリーを summary VIEW にも露出（読み取り用）
DROP VIEW IF EXISTS garmin_daily_summary;

CREATE VIEW garmin_daily_summary
WITH (security_invoker = true)
AS
SELECT
  d.user_id,
  d.date,
  d.synced_at,
  d.sync_status,
  (d.api_responses->'get_hrv_data'->'hrvSummary'->>'lastNightAvg')::numeric AS hrv_last_night_avg,
  (d.api_responses->'get_hrv_data'->'hrvSummary'->>'weeklyAvg')::numeric AS hrv_weekly_avg,
  d.api_responses->'get_hrv_data'->'hrvSummary'->>'status' AS hrv_status,
  (d.api_responses->'get_body_battery'->0->>'charged')::numeric AS bb_charged,
  (d.api_responses->'get_body_battery'->0->>'drained')::numeric AS bb_drained,
  ((d.api_responses->'get_body_battery'->0->>'charged')::numeric
    - (d.api_responses->'get_body_battery'->0->>'drained')::numeric) AS bb_net,
  (d.api_responses->'get_sleep_data'->'dailySleepDTO'->'sleepScores'->'overall'->>'value')::int AS sleep_score,
  d.api_responses->'get_sleep_data'->'dailySleepDTO'->'sleepScores'->'overall'->>'qualifierKey' AS sleep_qualifier,
  ((d.api_responses->'get_sleep_data'->'dailySleepDTO'->>'sleepTimeSeconds')::int / 60) AS sleep_minutes,
  ts.training_phrase,
  ts.acwr,
  (d.api_responses->'get_training_status'->'mostRecentVO2Max'->'generic'->>'vo2MaxValue')::numeric AS vo2max,
  (d.api_responses->'get_stats'->>'totalKilocalories')::numeric AS total_calories_kcal,
  (d.api_responses->'get_stats'->>'activeKilocalories')::numeric AS active_calories_kcal,
  (d.api_responses->'get_stats'->>'bmrKilocalories')::numeric AS bmr_calories_kcal
FROM garmin_daily_archive d
LEFT JOIN LATERAL (
  SELECT
    v.value->>'trainingStatusFeedbackPhrase' AS training_phrase,
    (v.value->'acuteTrainingLoadDTO'->>'dailyAcuteChronicWorkloadRatio')::numeric AS acwr
  FROM jsonb_each(
    d.api_responses->'get_training_status'->'mostRecentTrainingStatus'->'latestTrainingStatusData'
  ) AS v(key, value)
  WHERE (v.value->>'primaryTrainingDevice')::boolean = true
  LIMIT 1
) ts ON true;

GRANT SELECT ON garmin_daily_summary TO authenticated;
