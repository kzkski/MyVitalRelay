-- Garmin 同期: Claude トリガー + JSON アーカイブ（Issue #15）
-- 設計: docs/claude-garmin-access.md, docs/garmin-sync-ops.md
-- ※本番適用: .github/workflows/prod-db-migrate.yml または supabase db push

-- ---------------------------------------------------------------------------
-- 0. Storage バケット
-- ---------------------------------------------------------------------------

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES
  ('garmin-fit', 'garmin-fit', false, 52428800, ARRAY['application/zip', 'application/octet-stream']),
  ('garmin-json', 'garmin-json', false, 52428800, ARRAY['application/json'])
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS garmin_fit_owner_read ON storage.objects;
CREATE POLICY garmin_fit_owner_read ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id = 'garmin-fit'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

DROP POLICY IF EXISTS garmin_json_owner_read ON storage.objects;
CREATE POLICY garmin_json_owner_read ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id = 'garmin-json'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

-- ---------------------------------------------------------------------------
-- 1. Garmin OAuth トークン
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS garmin_oauth_tokens (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id),
  token_store jsonb NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE garmin_oauth_tokens ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- 2. 同期リクエスト
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS garmin_sync_request (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL DEFAULT auth.uid() REFERENCES auth.users(id),
  scope text NOT NULL CHECK (scope IN ('activities', 'daily', 'all')),
  date_from date NOT NULL,
  date_to date NOT NULL,
  trigger_source text NOT NULL DEFAULT 'claude'
    CHECK (trigger_source IN ('healthkit', 'claude', 'manual')),
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'running', 'complete', 'partial', 'failed')),
  progress jsonb NOT NULL DEFAULT '{}'::jsonb,
  error_message text,
  requested_at timestamptz NOT NULL DEFAULT now(),
  started_at timestamptz,
  completed_at timestamptz,
  CHECK (date_from <= date_to)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_garmin_sync_request_pending_dedup
  ON garmin_sync_request (user_id, scope, date_from, date_to)
  WHERE status = 'pending';

CREATE INDEX IF NOT EXISTS idx_garmin_sync_request_pending
  ON garmin_sync_request (requested_at)
  WHERE status = 'pending';

CREATE INDEX IF NOT EXISTS idx_garmin_sync_request_user_status
  ON garmin_sync_request (user_id, status, requested_at);

ALTER TABLE garmin_sync_request ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS garmin_sync_request_owner_select ON garmin_sync_request;
CREATE POLICY garmin_sync_request_owner_select ON garmin_sync_request
  FOR SELECT USING (auth.uid() = user_id);

DROP POLICY IF EXISTS garmin_sync_request_owner_insert ON garmin_sync_request;
CREATE POLICY garmin_sync_request_owner_insert ON garmin_sync_request
  FOR INSERT WITH CHECK (auth.uid() = user_id);

-- ---------------------------------------------------------------------------
-- 3. アクティビティアーカイブ
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS garmin_activity_archive (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id),
  garmin_activity_id bigint NOT NULL,
  activity_type_key text,
  activity_name text,
  start_time_local timestamptz,
  duration_sec numeric,
  summary jsonb NOT NULL DEFAULT '{}'::jsonb,
  fit_parsed jsonb NOT NULL DEFAULT '{}'::jsonb,
  api_responses jsonb NOT NULL DEFAULT '{}'::jsonb,
  fit_storage_path text,
  fit_parsed_storage_path text,
  api_json_storage_path text,
  training_log_id uuid REFERENCES training_log(id),
  sync_request_id uuid REFERENCES garmin_sync_request(id),
  sync_status text NOT NULL DEFAULT 'complete'
    CHECK (sync_status IN ('complete', 'partial', 'failed')),
  sync_errors jsonb NOT NULL DEFAULT '[]'::jsonb,
  synced_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, garmin_activity_id)
);

CREATE INDEX IF NOT EXISTS idx_garmin_activity_archive_user_start
  ON garmin_activity_archive (user_id, start_time_local);

CREATE INDEX IF NOT EXISTS idx_garmin_activity_archive_unlinked
  ON garmin_activity_archive (user_id, start_time_local)
  WHERE training_log_id IS NULL;

ALTER TABLE garmin_activity_archive ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS garmin_activity_archive_owner ON garmin_activity_archive;
CREATE POLICY garmin_activity_archive_owner ON garmin_activity_archive
  FOR SELECT USING (auth.uid() = user_id);

-- ---------------------------------------------------------------------------
-- 4. 日次アーカイブ（Phase 1.5 で job 実装）
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS garmin_daily_archive (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id),
  date date NOT NULL,
  api_responses jsonb NOT NULL DEFAULT '{}'::jsonb,
  api_json_storage_path text,
  sync_request_id uuid REFERENCES garmin_sync_request(id),
  sync_status text NOT NULL DEFAULT 'complete'
    CHECK (sync_status IN ('complete', 'partial', 'failed')),
  sync_errors jsonb NOT NULL DEFAULT '[]'::jsonb,
  synced_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, date)
);

ALTER TABLE garmin_daily_archive ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS garmin_daily_archive_owner ON garmin_daily_archive;
CREATE POLICY garmin_daily_archive_owner ON garmin_daily_archive
  FOR SELECT USING (auth.uid() = user_id);

-- ---------------------------------------------------------------------------
-- 5. ジョブ用ヘルパー
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION reset_stale_garmin_sync_requests(stale_minutes integer DEFAULT 30)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  affected integer;
BEGIN
  UPDATE garmin_sync_request
  SET status = 'pending',
      started_at = NULL,
      error_message = COALESCE(error_message, '') || ' [stale running reset]'
  WHERE status = 'running'
    AND started_at < now() - (stale_minutes || ' minutes')::interval;

  GET DIAGNOSTICS affected = ROW_COUNT;
  RETURN affected;
END;
$$;

CREATE OR REPLACE FUNCTION expire_old_pending_garmin_sync_requests(max_age_hours integer DEFAULT 24)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  affected integer;
BEGIN
  UPDATE garmin_sync_request
  SET status = 'failed',
      completed_at = now(),
      error_message = COALESCE(error_message, '') || ' [pending expired]'
  WHERE status = 'pending'
    AND requested_at < now() - (max_age_hours || ' hours')::interval;

  GET DIAGNOSTICS affected = ROW_COUNT;
  RETURN affected;
END;
$$;

CREATE OR REPLACE FUNCTION link_garmin_activity_training_log(p_user_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  affected integer;
BEGIN
  UPDATE garmin_activity_archive a
  SET training_log_id = t.id
  FROM training_log t
  WHERE a.user_id = p_user_id
    AND t.user_id = p_user_id
    AND t.data_source = 'garmin'
    AND a.training_log_id IS NULL
    AND a.start_time_local IS NOT NULL
    AND t.start_time IS NOT NULL
    AND t.start_time BETWEEN a.start_time_local - interval '120 seconds'
                         AND a.start_time_local + interval '120 seconds'
    AND (
      a.duration_sec IS NULL
      OR t.duration_min IS NULL
      OR abs(t.duration_min * 60 - a.duration_sec) <= 120
    );

  GET DIAGNOSTICS affected = ROW_COUNT;
  RETURN affected;
END;
$$;

REVOKE ALL ON FUNCTION reset_stale_garmin_sync_requests(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION expire_old_pending_garmin_sync_requests(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION link_garmin_activity_training_log(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION reset_stale_garmin_sync_requests(integer) TO service_role;
GRANT EXECUTE ON FUNCTION expire_old_pending_garmin_sync_requests(integer) TO service_role;
GRANT EXECUTE ON FUNCTION link_garmin_activity_training_log(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 6. Claude 向け View
-- ---------------------------------------------------------------------------

DROP VIEW IF EXISTS garmin_activity_claude;
DROP VIEW IF EXISTS garmin_activity_claude_summary;
DROP VIEW IF EXISTS garmin_daily_claude;

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
  t.avg_hr,
  t.rpe,
  t.condition_notes,
  a.summary->>'averageHR' AS avg_hr_garmin,
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

CREATE VIEW garmin_daily_claude
WITH (security_invoker = true)
AS
SELECT
  user_id,
  date,
  synced_at,
  sync_status,
  api_responses->'get_training_readiness' AS training_readiness,
  api_responses->'get_hrv_data' AS hrv,
  api_responses->'get_body_battery' AS body_battery,
  api_responses->'get_sleep_data' AS sleep,
  api_json_storage_path,
  api_responses
FROM garmin_daily_archive;

GRANT SELECT ON garmin_activity_claude_summary TO authenticated;
GRANT SELECT ON garmin_activity_claude TO authenticated;
GRANT SELECT ON garmin_daily_claude TO authenticated;
