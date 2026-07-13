-- Issue #22: 日次データ用の軽量 VIEW（garmin_daily_claude は 1 行 ~573KB のため）
-- garmin_activity_claude_summary と同じ思想でスカラー値のみを露出する。

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
  (d.api_responses->'get_training_status'->'mostRecentVO2Max'->'generic'->>'vo2MaxValue')::numeric AS vo2max
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
