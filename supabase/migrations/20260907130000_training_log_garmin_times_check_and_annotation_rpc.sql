-- Issue #33 Phase 2: garmin times CHECK + activity type map helpers + annotation RPC
-- Prerequisite: 20260907120000_merge_null_key_training_log_duplicates.sql applied
--   (VALIDATE fails if any data_source='garmin' row still has NULL start_time/end_time)

-- 1) CHECK (new writes immediately; existing scanned on VALIDATE)
ALTER TABLE training_log
  ADD CONSTRAINT training_log_garmin_requires_times_check
  CHECK (
    data_source <> 'garmin'
    OR (start_time IS NOT NULL AND end_time IS NOT NULL)
  ) NOT VALID;

-- 2) Map helpers (HK WorkoutSnapshot.displayName / WorkoutMapper.discipline)
CREATE OR REPLACE FUNCTION garmin_activity_type_to_workout_type(p_key text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_key
    WHEN 'running' THEN 'Running'
    WHEN 'treadmill_running' THEN 'Running'
    WHEN 'walking' THEN 'Walking'
    WHEN 'stair_climbing' THEN 'StairClimbing'
    WHEN 'strength_training' THEN 'TraditionalStrengthTraining'
    WHEN 'virtual_ride' THEN 'Cycling'
    WHEN 'cycling' THEN 'Cycling'
    WHEN 'road_biking' THEN 'Cycling'
    WHEN 'indoor_cycling' THEN 'Cycling'
    WHEN 'swimming' THEN 'Swimming'
    WHEN 'lap_swimming' THEN 'Swimming'
    WHEN 'open_water_swimming' THEN 'Swimming'
    WHEN 'hiking' THEN 'Hiking'
    WHEN 'elliptical' THEN 'Elliptical'
    WHEN 'rowing' THEN 'Rowing'
    WHEN 'indoor_rowing' THEN 'Rowing'
    WHEN 'yoga' THEN 'Yoga'
    WHEN 'floor_climbing' THEN 'Other(3000)'
    ELSE NULL
  END;
$$;

CREATE OR REPLACE FUNCTION garmin_activity_type_to_discipline(p_key text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE garmin_activity_type_to_workout_type(p_key)
    WHEN 'Running' THEN 'run'
    WHEN 'Walking' THEN 'run'
    WHEN 'Cycling' THEN 'bike'
    WHEN 'Swimming' THEN 'swim'
    WHEN 'TraditionalStrengthTraining' THEN 'strength'
    WHEN 'FunctionalStrengthTraining' THEN 'strength'
    WHEN NULL THEN NULL
    ELSE 'other'
  END;
$$;

REVOKE ALL ON FUNCTION garmin_activity_type_to_workout_type(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION garmin_activity_type_to_discipline(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION garmin_activity_type_to_workout_type(text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION garmin_activity_type_to_discipline(text) TO authenticated, service_role;

-- 3) Claude annotation RPC (resolve by training_log_id or garmin_activity_id only)
CREATE OR REPLACE FUNCTION upsert_training_log_annotation(
  p_training_log_id uuid DEFAULT NULL,
  p_garmin_activity_id bigint DEFAULT NULL,
  p_rpe smallint DEFAULT NULL,
  p_condition_notes text DEFAULT NULL,
  p_notes text DEFAULT NULL,
  p_surface text DEFAULT NULL,
  p_equipment text DEFAULT NULL,
  p_allow_insert_from_archive boolean DEFAULT true
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_target_id uuid;
  v_arch garmin_activity_archive%ROWTYPE;
  v_workout_type text;
  v_discipline text;
  v_start timestamptz;
  v_end timestamptz;
  v_date date;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'upsert_training_log_annotation: not authenticated';
  END IF;

  IF p_training_log_id IS NULL AND p_garmin_activity_id IS NULL THEN
    RAISE EXCEPTION
      'upsert_training_log_annotation: provide p_training_log_id or p_garmin_activity_id';
  END IF;

  IF p_training_log_id IS NOT NULL THEN
    SELECT t.id INTO v_target_id
    FROM training_log t
    WHERE t.id = p_training_log_id
      AND t.user_id = v_uid;
    IF v_target_id IS NULL THEN
      RAISE EXCEPTION
        'upsert_training_log_annotation: training_log % not found for user',
        p_training_log_id;
    END IF;

  ELSE
    SELECT a.* INTO v_arch
    FROM garmin_activity_archive a
    WHERE a.user_id = v_uid
      AND a.garmin_activity_id = p_garmin_activity_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION
        'upsert_training_log_annotation: garmin_activity_id % not found',
        p_garmin_activity_id;
    END IF;

    v_workout_type := garmin_activity_type_to_workout_type(v_arch.activity_type_key);
    v_discipline := garmin_activity_type_to_discipline(v_arch.activity_type_key);

    IF v_arch.training_log_id IS NOT NULL THEN
      SELECT t.id INTO v_target_id
      FROM training_log t
      WHERE t.id = v_arch.training_log_id
        AND t.user_id = v_uid;
      IF v_target_id IS NULL THEN
        RAISE EXCEPTION
          'upsert_training_log_annotation: linked training_log % missing',
          v_arch.training_log_id;
      END IF;

    ELSE
      IF v_workout_type IS NOT NULL THEN
        SELECT t.id INTO v_target_id
        FROM training_log t
        WHERE t.user_id = v_uid
          AND t.data_source = 'garmin'
          AND t.start_time IS NOT NULL
          AND v_arch.start_time_local IS NOT NULL
          AND t.start_time BETWEEN v_arch.start_time_local - interval '120 seconds'
                               AND v_arch.start_time_local + interval '120 seconds'
          AND (
            v_arch.duration_sec IS NULL
            OR t.duration_min IS NULL
            OR abs(t.duration_min * 60 - v_arch.duration_sec) <= 120
          )
          AND t.workout_type = v_workout_type
        ORDER BY abs(extract(epoch FROM (t.start_time - v_arch.start_time_local)))
        LIMIT 1;

        IF v_target_id IS NOT NULL THEN
          UPDATE garmin_activity_archive
          SET training_log_id = v_target_id
          WHERE id = v_arch.id
            AND training_log_id IS NULL;
        END IF;
      END IF;

      IF v_target_id IS NULL THEN
        IF NOT p_allow_insert_from_archive THEN
          RAISE EXCEPTION
            'upsert_training_log_annotation: no training_log for activity % (insert disabled)',
            p_garmin_activity_id;
        END IF;
        IF v_workout_type IS NULL OR v_discipline IS NULL THEN
          RAISE EXCEPTION
            'upsert_training_log_annotation: unknown activity_type_key %',
            v_arch.activity_type_key;
        END IF;
        IF v_arch.start_time_local IS NULL OR v_arch.duration_sec IS NULL THEN
          RAISE EXCEPTION
            'upsert_training_log_annotation: archive % missing start/duration',
            p_garmin_activity_id;
        END IF;

        v_start := v_arch.start_time_local;
        v_end := v_arch.start_time_local
          + make_interval(secs => v_arch.duration_sec::double precision);
        v_date := (v_start AT TIME ZONE 'Asia/Tokyo')::date;

        INSERT INTO training_log (
          user_id, date, data_source,
          healthkit_uuid, discipline, workout_type,
          start_time, end_time, duration_min,
          calories_burned,
          rpe, condition_notes, notes, surface, equipment,
          updated_at
        ) VALUES (
          v_uid, v_date, 'garmin',
          NULL, v_discipline, v_workout_type,
          v_start, v_end, v_arch.duration_sec / 60.0,
          NULL,
          p_rpe, p_condition_notes, p_notes, p_surface, p_equipment,
          now()
        )
        RETURNING id INTO v_target_id;

        UPDATE garmin_activity_archive
        SET training_log_id = v_target_id
        WHERE id = v_arch.id;

        RETURN v_target_id;
      END IF;
    END IF;
  END IF;

  UPDATE training_log t
  SET
    rpe = CASE WHEN p_rpe IS NOT NULL THEN p_rpe ELSE t.rpe END,
    condition_notes = CASE
      WHEN p_condition_notes IS NOT NULL THEN p_condition_notes ELSE t.condition_notes END,
    notes = CASE WHEN p_notes IS NOT NULL THEN p_notes ELSE t.notes END,
    surface = CASE WHEN p_surface IS NOT NULL THEN p_surface ELSE t.surface END,
    equipment = CASE WHEN p_equipment IS NOT NULL THEN p_equipment ELSE t.equipment END,
    updated_at = now()
  WHERE t.id = v_target_id
    AND t.user_id = v_uid;

  RETURN v_target_id;
END;
$$;

REVOKE ALL ON FUNCTION upsert_training_log_annotation(
  uuid, bigint, smallint, text, text, text, text, boolean
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION upsert_training_log_annotation(
  uuid, bigint, smallint, text, text, text, text, boolean
) TO authenticated;
GRANT EXECUTE ON FUNCTION upsert_training_log_annotation(
  uuid, bigint, smallint, text, text, text, text, boolean
) TO service_role;

-- 4) Validate existing rows (requires Phase 1 cleanup)
ALTER TABLE training_log
  VALIDATE CONSTRAINT training_log_garmin_requires_times_check;
