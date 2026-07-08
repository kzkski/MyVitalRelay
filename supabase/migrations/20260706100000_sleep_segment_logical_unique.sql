-- sleep_segment: 論理重複のクリーンアップ + 論理キー UNIQUE（Issue #4）

-- 1. 重複行を削除（HealthKit 現行に近いよう created_at が新しい方を残す）
DELETE FROM sleep_segment s
USING (
  SELECT id,
         ROW_NUMBER() OVER (
           PARTITION BY user_id, start_time, end_time, stage
           ORDER BY created_at DESC
         ) AS rn
  FROM sleep_segment
) ranked
WHERE s.id = ranked.id AND ranked.rn > 1;

-- 2. 論理キー UNIQUE 制約
ALTER TABLE sleep_segment
  ADD CONSTRAINT sleep_segment_logical_unique
  UNIQUE (user_id, start_time, end_time, stage);
