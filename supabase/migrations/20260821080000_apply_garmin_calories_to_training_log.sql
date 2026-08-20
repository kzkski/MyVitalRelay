-- Garmin archive の calories（合計）を training_log.calories_burned に反映する。
-- Issue #28
-- 抽出: COALESCE(summaryDTO.calories, top-level calories)
-- 意味論: Garmin 行はセッション合計 kcal（BMR 込み）。life_fitness / manual は触らない。

CREATE OR REPLACE FUNCTION apply_garmin_calories_to_training_log(p_user_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  affected integer;
BEGIN
  UPDATE training_log t
  SET
    calories_burned = COALESCE(
      a.summary->'summaryDTO'->>'calories',
      a.summary->>'calories'
    )::numeric,
    updated_at = now()
  FROM garmin_activity_archive a
  WHERE a.training_log_id = t.id
    AND a.user_id = p_user_id
    AND t.user_id = p_user_id
    AND t.data_source = 'garmin'
    AND COALESCE(
          a.summary->'summaryDTO'->>'calories',
          a.summary->>'calories'
        ) IS NOT NULL
    AND t.calories_burned IS DISTINCT FROM COALESCE(
          a.summary->'summaryDTO'->>'calories',
          a.summary->>'calories'
        )::numeric;

  GET DIAGNOSTICS affected = ROW_COUNT;
  RETURN affected;
END;
$$;

REVOKE ALL ON FUNCTION apply_garmin_calories_to_training_log(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION apply_garmin_calories_to_training_log(uuid) TO service_role;

-- バックフィル（全リンク済み garmin 行・差分のみ）
UPDATE training_log t
SET
  calories_burned = COALESCE(
    a.summary->'summaryDTO'->>'calories',
    a.summary->>'calories'
  )::numeric,
  updated_at = now()
FROM garmin_activity_archive a
WHERE a.training_log_id = t.id
  AND t.data_source = 'garmin'
  AND COALESCE(
        a.summary->'summaryDTO'->>'calories',
        a.summary->>'calories'
      ) IS NOT NULL
  AND t.calories_burned IS DISTINCT FROM COALESCE(
        a.summary->'summaryDTO'->>'calories',
        a.summary->>'calories'
      )::numeric;
