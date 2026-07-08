-- training_log: 論理重複のクリーンアップ + 論理キー UNIQUE（Issue #8）
-- sleep_segment (20260706100000) をベースに、手動入力列優先 tie-break を追加

-- 1. 重複行を削除
--    tie-break 優先順位:
--      (a) rpe / condition_notes / notes のいずれかが非 NULL の行を優先
--      (b) 同順位なら created_at DESC（HealthKit 現行 UUID に近い方）
DELETE FROM training_log t
USING (
  SELECT id,
         ROW_NUMBER() OVER (
           PARTITION BY user_id, start_time, end_time, workout_type
           ORDER BY
             (CASE
               WHEN rpe IS NOT NULL
                 OR condition_notes IS NOT NULL
                 OR notes IS NOT NULL
               THEN 0 ELSE 1
             END) ASC,
             created_at DESC
         ) AS rn
  FROM training_log
  WHERE start_time IS NOT NULL
    AND end_time IS NOT NULL
    AND workout_type IS NOT NULL
) ranked
WHERE t.id = ranked.id AND ranked.rn > 1;

-- 2. 論理キー UNIQUE 制約
ALTER TABLE training_log
  ADD CONSTRAINT training_log_logical_unique
  UNIQUE (user_id, start_time, end_time, workout_type);
