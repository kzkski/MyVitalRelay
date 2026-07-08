-- daily_activity_summary: 日次アクティブ/基礎代謝カロリーのリレー先
-- ※本番（ykcbevvorckcigwwtftw）へ適用済み。履歴整合用。ketolog 初回適用時も冪等。

CREATE TABLE IF NOT EXISTS daily_activity_summary (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id),
  date date NOT NULL,
  active_calories_kcal numeric,
  basal_calories_kcal numeric,
  notes text,
  synced_at timestamptz DEFAULT now()
);

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'daily_activity_summary_user_id_date_key'
  ) THEN
    ALTER TABLE daily_activity_summary
      ADD CONSTRAINT daily_activity_summary_user_id_date_key
      UNIQUE (user_id, date);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_daily_activity_summary_user_date
  ON daily_activity_summary (user_id, date);

ALTER TABLE daily_activity_summary ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS daily_activity_summary_owner_access ON daily_activity_summary;
CREATE POLICY daily_activity_summary_owner_access ON daily_activity_summary
  FOR ALL USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
