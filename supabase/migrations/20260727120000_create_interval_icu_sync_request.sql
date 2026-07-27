-- Intervals.icu wellness（体重・体脂肪）同期キュー（Issue #24）
-- 設計: docs/interval-icu-sync-ops.md
-- アーキテクチャ: Edge Function が直接 claim + PUT（GHA はバックフィル/drain 専用）

CREATE TABLE interval_icu_sync_request (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL DEFAULT auth.uid() REFERENCES auth.users(id),
  date date NOT NULL,
  -- DEFAULT なし: 呼び出し側（iOS Enqueuer・手動 SQL）に明示を必須化
  trigger_source text NOT NULL
    CHECK (trigger_source IN ('healthkit', 'claude', 'manual')),
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'running', 'partial', 'complete', 'failed')),
  error_message text,
  requested_at timestamptz NOT NULL DEFAULT now(),
  started_at timestamptz,
  completed_at timestamptz
);

-- pending 中は同一 (user_id, date) を 1 行に制限
CREATE UNIQUE INDEX idx_interval_icu_sync_request_pending_dedup
  ON interval_icu_sync_request (user_id, date)
  WHERE status = 'pending';

CREATE INDEX idx_interval_icu_sync_request_pending
  ON interval_icu_sync_request (requested_at)
  WHERE status = 'pending';

CREATE INDEX idx_interval_icu_sync_request_user_status
  ON interval_icu_sync_request (user_id, status, requested_at);

ALTER TABLE interval_icu_sync_request ENABLE ROW LEVEL SECURITY;

CREATE POLICY interval_icu_sync_request_owner_select ON interval_icu_sync_request
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY interval_icu_sync_request_owner_insert ON interval_icu_sync_request
  FOR INSERT WITH CHECK (auth.uid() = user_id);

-- Edge Function から呼ぶ自己修復ヘルパー（schedule に依存しない）
CREATE OR REPLACE FUNCTION reset_stale_interval_icu_sync_requests(stale_minutes integer DEFAULT 15)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  affected integer;
BEGIN
  UPDATE interval_icu_sync_request
  SET status = 'pending',
      started_at = NULL,
      error_message = COALESCE(error_message, '') || ' [stale running reset]'
  WHERE status = 'running'
    AND started_at < now() - (stale_minutes || ' minutes')::interval;
  GET DIAGNOSTICS affected = ROW_COUNT;
  RETURN affected;
END;
$$;

CREATE OR REPLACE FUNCTION expire_old_pending_interval_icu_sync_requests(max_age_hours integer DEFAULT 24)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  affected integer;
BEGIN
  UPDATE interval_icu_sync_request
  SET status = 'failed',
      completed_at = now(),
      error_message = COALESCE(error_message, '') || ' [pending expired]'
  WHERE status = 'pending'
    AND requested_at < now() - (max_age_hours || ' hours')::interval;
  GET DIAGNOSTICS affected = ROW_COUNT;
  RETURN affected;
END;
$$;

REVOKE ALL ON FUNCTION reset_stale_interval_icu_sync_requests(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION expire_old_pending_interval_icu_sync_requests(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION reset_stale_interval_icu_sync_requests(integer) TO service_role;
GRANT EXECUTE ON FUNCTION expire_old_pending_interval_icu_sync_requests(integer) TO service_role;
