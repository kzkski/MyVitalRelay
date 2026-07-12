-- Garmin 同期: Claude トリガー + JSON アーカイブ（Issue #15）
-- 設計: docs/claude-garmin-access.md
-- ※本番適用前に get_advisors で RLS 確認

-- ---------------------------------------------------------------------------
-- 1. 同期リクエスト（Claude が INSERT → ジョブが処理）
-- ---------------------------------------------------------------------------

CREATE TABLE garmin_sync_request (
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

-- 同一ユーザー・期間・scope の pending が重複しない（HealthKit 連続同期対策）
CREATE UNIQUE INDEX idx_garmin_sync_request_pending_dedup
  ON garmin_sync_request (user_id, scope, date_from, date_to)
  WHERE status = 'pending';

CREATE INDEX idx_garmin_sync_request_pending
  ON garmin_sync_request (requested_at)
  WHERE status = 'pending';

ALTER TABLE garmin_sync_request ENABLE ROW LEVEL SECURITY;

CREATE POLICY garmin_sync_request_owner_select ON garmin_sync_request
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY garmin_sync_request_owner_insert ON garmin_sync_request
  FOR INSERT WITH CHECK (auth.uid() = user_id);

-- UPDATE は service_role（Sync Job）のみ。authenticated からの UPDATE は許可しない。

-- ---------------------------------------------------------------------------
-- 2. アクティビティアーカイブ
-- ---------------------------------------------------------------------------

CREATE TABLE garmin_activity_archive (
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
  training_log_id uuid REFERENCES training_log(id),
  sync_request_id uuid REFERENCES garmin_sync_request(id),
  sync_status text NOT NULL DEFAULT 'complete'
    CHECK (sync_status IN ('complete', 'partial', 'failed')),
  sync_errors jsonb NOT NULL DEFAULT '[]'::jsonb,
  synced_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, garmin_activity_id)
);

CREATE INDEX idx_garmin_activity_archive_user_start
  ON garmin_activity_archive (user_id, start_time_local);

ALTER TABLE garmin_activity_archive ENABLE ROW LEVEL SECURITY;

CREATE POLICY garmin_activity_archive_owner ON garmin_activity_archive
  FOR SELECT USING (auth.uid() = user_id);

-- INSERT/UPDATE は service_role（Sync Job）のみ

-- ---------------------------------------------------------------------------
-- 3. 日次アーカイブ
-- ---------------------------------------------------------------------------

CREATE TABLE garmin_daily_archive (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id),
  date date NOT NULL,
  api_responses jsonb NOT NULL DEFAULT '{}'::jsonb,
  sync_request_id uuid REFERENCES garmin_sync_request(id),
  sync_status text NOT NULL DEFAULT 'complete'
    CHECK (sync_status IN ('complete', 'partial', 'failed')),
  sync_errors jsonb NOT NULL DEFAULT '[]'::jsonb,
  synced_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, date)
);

ALTER TABLE garmin_daily_archive ENABLE ROW LEVEL SECURITY;

CREATE POLICY garmin_daily_archive_owner ON garmin_daily_archive
  FOR SELECT USING (auth.uid() = user_id);

-- ---------------------------------------------------------------------------
-- 4. Claude 向け View（security_invoker = RLS 継承）
-- ---------------------------------------------------------------------------

CREATE VIEW garmin_activity_claude
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
  a.summary,
  a.fit_parsed,
  a.api_responses
FROM garmin_activity_archive a
LEFT JOIN training_log t ON t.id = a.training_log_id;

CREATE VIEW garmin_daily_claude
WITH (security_invoker = true)
AS
SELECT
  user_id,
  date,
  synced_at,
  api_responses->'get_training_readiness' AS training_readiness,
  api_responses->'get_hrv_data' AS hrv,
  api_responses->'get_body_battery' AS body_battery,
  api_responses->'get_sleep_data' AS sleep,
  api_responses
FROM garmin_daily_archive;

GRANT SELECT ON garmin_activity_claude TO authenticated;
GRANT SELECT ON garmin_daily_claude TO authenticated;
