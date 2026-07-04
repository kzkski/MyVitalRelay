-- training_log: 1 HealthKitワークアウトセッション = 1行
-- ※このマイグレーションは 2026-07-04 にSupabase本番（ykcbevvorckcigwwtftw）へ適用済み。
-- 引き継ぎ資料の最終DDLに準拠。変更点は healthkit_uuid を部分UNIQUEインデックスではなく
-- 通常のUNIQUE制約にした点のみ（NULLは重複扱いされないため意味論は同一。
-- PostgRESTの upsert on_conflict が部分インデックスでは競合推論できないための変更）。
CREATE TABLE training_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id),
  date date NOT NULL,
  data_source text NOT NULL CHECK (data_source IN ('garmin','life_fitness','manual')),
  healthkit_uuid uuid UNIQUE,
  discipline text NOT NULL CHECK (discipline IN ('run','bike','swim','brick','strength','other')),
  workout_type text,                           -- HealthKit上のworkoutActivityType文字列（生値をそのまま保持）
  start_time timestamptz,
  end_time timestamptz,
  duration_min numeric,                        -- HealthKit由来は自動算出、手動記録（筋トレ等）は申告値

  -- 共通メトリクス（取得できないソースは自然にNULL）
  distance_km numeric,                         -- Life Fitness由来はウォーキング＋ランニング合算値、Garmin由来はGPS実距離
  avg_speed_kmh numeric,
  calories_burned numeric,                     -- daily_logの既存命名に合わせて統一
  avg_hr numeric,                              -- Life Fitness由来は基本NULL（Apple Watch非所持のため）
  max_hr numeric,                              -- 同上
  elevation_gain_m numeric,                    -- ラン・バイクのみ、水泳はNULL
  hr_zone_minutes jsonb,                       -- iOS27以降のHKWorkoutZoneGroup対応後に順次埋める想定。当面は常にNULL

  -- 種目固有メトリクス（将来のトライアスロン移行を見据えた汎用設計）
  cadence numeric,                              -- ラン:歩数/分、バイク:rpm。単位はdisciplineから判別
  power_watts numeric,                          -- 現状は常にNULL。将来パワーメーター導入時にそのまま埋まる
  stroke_count numeric,                         -- 水泳のみ（HealthKit: swimmingStrokeCount）
  stroke_style text CHECK (stroke_style IN ('freestyle','backstroke','breaststroke','butterfly','mixed','unknown')),

  equipment text,                               -- 例: EvoRide Speed 3／ロードバイク名等、種目を問わず汎用命名
  surface text,                                 -- トレッドミル／舗装路／トラック／プール等

  rpe smallint CHECK (rpe BETWEEN 1 AND 10),    -- 会話内でClaudeが聞き取って記録する主観的運動強度
  srpe numeric GENERATED ALWAYS AS (duration_min * rpe) STORED,  -- 週次負荷モニタリング用の内的負荷指標

  condition_notes text,                         -- 部位を限定しない体調・気分の自由記述。Claudeが会話から書き取る
  notes text,
  metadata jsonb DEFAULT '{}'::jsonb,           -- 想定外・未マッピング項目の受け皿

  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

ALTER TABLE training_log ENABLE ROW LEVEL SECURITY;

CREATE POLICY "training_log_owner_access" ON training_log
  FOR ALL USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

CREATE INDEX idx_training_log_user_date ON training_log(user_id, date);
