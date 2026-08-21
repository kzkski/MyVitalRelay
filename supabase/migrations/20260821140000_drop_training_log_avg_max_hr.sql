-- training_log から HealthKit 由来の avg_hr / max_hr を削除し、
-- Claude 向け activity VIEW を Garmin archive (summaryDTO) 参照に切替する。
-- Issue #27
--
-- 注意:
-- - garmin_daily_claude は触らない
-- - distance / cadence / power 等の summary キーのパスは変更しない（HR のみ）

DROP VIEW IF EXISTS garmin_activity_claude;
DROP VIEW IF EXISTS garmin_activity_claude_summary;

ALTER TABLE training_log DROP COLUMN IF EXISTS avg_hr;
ALTER TABLE training_log DROP COLUMN IF EXISTS max_hr;

CREATE VIEW garmin_activity_claude_summary
WITH (security_invoker = true)
AS
SELECT
  a.id,
  a.user_id,
  a.garmin_activity_id,
  a.activity_type_key,
  a.activity_name,
  a.start_time_local,
  a.duration_sec,
  a.synced_at,
  a.sync_status,
  a.training_log_id,
  t.date AS training_log_date,
  t.discipline,
  t.distance_km,
  t.rpe,
  t.condition_notes,
  (a.summary->'summaryDTO'->>'averageHR')::numeric AS avg_hr_garmin,
  (a.summary->'summaryDTO'->>'maxHR')::numeric AS max_hr_garmin,
  (a.summary->>'distance')::numeric AS distance_m,
  a.summary->>'averageRunningCadenceInStepsPerMinute' AS cadence_spm,
  a.summary->>'avgPower' AS avg_power_w,
  a.summary->>'aerobicTrainingEffect' AS aerobic_te,
  a.summary->>'activityTrainingLoad' AS training_load,
  (a.fit_parsed = '{}'::jsonb AND a.fit_parsed_storage_path IS NOT NULL) AS fit_parsed_in_storage,
  (a.api_responses = '{}'::jsonb AND a.api_json_storage_path IS NOT NULL) AS api_responses_in_storage
FROM garmin_activity_archive a
LEFT JOIN training_log t ON t.id = a.training_log_id;

CREATE VIEW garmin_activity_claude
WITH (security_invoker = true)
AS
SELECT
  s.*,
  a.summary,
  a.fit_parsed,
  a.api_responses,
  a.fit_storage_path,
  a.fit_parsed_storage_path,
  a.api_json_storage_path
FROM garmin_activity_claude_summary s
JOIN garmin_activity_archive a ON a.id = s.id;

GRANT SELECT ON garmin_activity_claude_summary TO authenticated;
GRANT SELECT ON garmin_activity_claude TO authenticated;
