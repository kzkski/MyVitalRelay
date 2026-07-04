-- body_composition_sample / sleep_segment: HealthKit 生データのリレー先
-- ※本番（ykcbevvorckcigwwtftw）へ 2026-07-04 に ketolog prod-db-migrate workflow で適用済み。

-- 体重・体脂肪: 体重計測定サンプル1件 = 1行（bodyMass / bodyFatPercentage は別 UUID になりうる）
CREATE TABLE body_composition_sample (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id),
  measured_at timestamptz NOT NULL,
  date date NOT NULL,
  weight_kg numeric(4, 1),
  body_fat_pct numeric(4, 1),
  healthkit_uuid uuid UNIQUE,
  source_name text,
  source_bundle_id text,
  metadata jsonb DEFAULT '{}'::jsonb,
  created_at timestamptz DEFAULT now()
);

CREATE INDEX idx_body_composition_user_measured
  ON body_composition_sample (user_id, measured_at);

ALTER TABLE body_composition_sample ENABLE ROW LEVEL SECURITY;

CREATE POLICY "body_composition_owner_access" ON body_composition_sample
  FOR ALL USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

-- 睡眠: sleepAnalysis セグメント1件 = 1行（asleep 系のみ。awake / inBed はアプリ側で除外）
CREATE TABLE sleep_segment (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id),
  start_time timestamptz NOT NULL,
  end_time timestamptz NOT NULL,
  stage text NOT NULL CHECK (stage IN ('core', 'deep', 'rem', 'unspecified')),
  duration_sec integer NOT NULL,
  healthkit_uuid uuid UNIQUE,
  metadata jsonb DEFAULT '{}'::jsonb,
  created_at timestamptz DEFAULT now()
);

CREATE INDEX idx_sleep_segment_user_start
  ON sleep_segment (user_id, start_time);

ALTER TABLE sleep_segment ENABLE ROW LEVEL SECURITY;

CREATE POLICY "sleep_segment_owner_access" ON sleep_segment
  FOR ALL USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
