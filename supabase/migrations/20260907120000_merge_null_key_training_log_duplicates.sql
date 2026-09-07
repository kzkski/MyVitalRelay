-- Issue #33 Phase 1: NULL-key Claude training_log rows ← HK orphan full-key rows
-- Prefer keep id = garmin_activity_archive.training_log_id
-- Idempotent: orphan missing → fill keys from archive if keep still NULL-keyed; else no-op
-- calories_burned: do not overwrite keep from orphan; align via apply_* at end (#28)
--
-- Dry-run (2026-09-07): orphan ids confirmed
--   keep 5fa5ea06-6e10-438b-b990-8d31fc631eb1 ↔ orphan 0b5c9517-7236-42fe-bbf1-48a4c5aae613 (activity 24108978987)
--   keep 42c84798-81a3-4f73-9caa-868f59cc7b3d ↔ orphan 3540330c-e2d3-4d6b-89ca-02c198ac32e0 (activity 24133970032)
-- Re-check orphan ids immediately before apply; they can change if HK backfill re-inserts.

DO $$
DECLARE
  v_keep_id uuid := '5fa5ea06-6e10-438b-b990-8d31fc631eb1';
  v_orphan_id uuid := '0b5c9517-7236-42fe-bbf1-48a4c5aae613';
  v_garmin_activity_id bigint := 24108978987;

  v_start timestamptz;
  v_end timestamptz;
  v_hk uuid;
  v_duration_min numeric;
  v_distance_km numeric;
  v_avg_speed_kmh numeric;
  v_hr_zone jsonb;
  v_elev numeric;
  v_stroke numeric;
  v_metadata jsonb;
  v_arch_start timestamptz;
  v_arch_duration numeric;
BEGIN
  SELECT
    o.start_time, o.end_time, o.healthkit_uuid,
    o.duration_min, o.distance_km, o.avg_speed_kmh,
    o.hr_zone_minutes, o.elevation_gain_m, o.stroke_count, o.metadata
  INTO
    v_start, v_end, v_hk,
    v_duration_min, v_distance_km, v_avg_speed_kmh,
    v_hr_zone, v_elev, v_stroke, v_metadata
  FROM training_log o
  WHERE o.id = v_orphan_id;

  IF FOUND THEN
    UPDATE training_log
    SET healthkit_uuid = NULL,
        start_time = NULL,
        end_time = NULL,
        updated_at = now()
    WHERE id = v_orphan_id;

    UPDATE training_log k
    SET
      start_time = v_start,
      end_time = v_end,
      healthkit_uuid = v_hk,
      duration_min = COALESCE(k.duration_min, v_duration_min),
      distance_km = COALESCE(k.distance_km, v_distance_km),
      avg_speed_kmh = COALESCE(k.avg_speed_kmh, v_avg_speed_kmh),
      hr_zone_minutes = COALESCE(k.hr_zone_minutes, v_hr_zone),
      elevation_gain_m = COALESCE(k.elevation_gain_m, v_elev),
      stroke_count = COALESCE(k.stroke_count, v_stroke),
      metadata = CASE
        WHEN k.metadata IS NULL OR k.metadata = '{}'::jsonb THEN COALESCE(v_metadata, '{}'::jsonb)
        ELSE k.metadata
      END,
      updated_at = now()
    WHERE k.id = v_keep_id;

    DELETE FROM training_log WHERE id = v_orphan_id;
  ELSE
    SELECT a.start_time_local, a.duration_sec
    INTO v_arch_start, v_arch_duration
    FROM garmin_activity_archive a
    WHERE a.garmin_activity_id = v_garmin_activity_id
      AND a.training_log_id = v_keep_id;

    IF FOUND THEN
      UPDATE training_log k
      SET
        start_time = COALESCE(k.start_time, v_arch_start),
        end_time = COALESCE(
          k.end_time,
          v_arch_start + make_interval(secs => v_arch_duration::double precision)
        ),
        duration_min = COALESCE(k.duration_min, v_arch_duration / 60.0),
        updated_at = now()
      WHERE k.id = v_keep_id
        AND (k.start_time IS NULL OR k.end_time IS NULL);
    END IF;
  END IF;
END $$;

DO $$
DECLARE
  v_keep_id uuid := '42c84798-81a3-4f73-9caa-868f59cc7b3d';
  v_orphan_id uuid := '3540330c-e2d3-4d6b-89ca-02c198ac32e0';
  v_garmin_activity_id bigint := 24133970032;

  v_start timestamptz;
  v_end timestamptz;
  v_hk uuid;
  v_duration_min numeric;
  v_distance_km numeric;
  v_avg_speed_kmh numeric;
  v_hr_zone jsonb;
  v_elev numeric;
  v_stroke numeric;
  v_metadata jsonb;
  v_arch_start timestamptz;
  v_arch_duration numeric;
BEGIN
  SELECT
    o.start_time, o.end_time, o.healthkit_uuid,
    o.duration_min, o.distance_km, o.avg_speed_kmh,
    o.hr_zone_minutes, o.elevation_gain_m, o.stroke_count, o.metadata
  INTO
    v_start, v_end, v_hk,
    v_duration_min, v_distance_km, v_avg_speed_kmh,
    v_hr_zone, v_elev, v_stroke, v_metadata
  FROM training_log o
  WHERE o.id = v_orphan_id;

  IF FOUND THEN
    UPDATE training_log
    SET healthkit_uuid = NULL,
        start_time = NULL,
        end_time = NULL,
        updated_at = now()
    WHERE id = v_orphan_id;

    UPDATE training_log k
    SET
      start_time = v_start,
      end_time = v_end,
      healthkit_uuid = v_hk,
      duration_min = COALESCE(k.duration_min, v_duration_min),
      distance_km = COALESCE(k.distance_km, v_distance_km),
      avg_speed_kmh = COALESCE(k.avg_speed_kmh, v_avg_speed_kmh),
      hr_zone_minutes = COALESCE(k.hr_zone_minutes, v_hr_zone),
      elevation_gain_m = COALESCE(k.elevation_gain_m, v_elev),
      stroke_count = COALESCE(k.stroke_count, v_stroke),
      metadata = CASE
        WHEN k.metadata IS NULL OR k.metadata = '{}'::jsonb THEN COALESCE(v_metadata, '{}'::jsonb)
        ELSE k.metadata
      END,
      updated_at = now()
    WHERE k.id = v_keep_id;

    DELETE FROM training_log WHERE id = v_orphan_id;
  ELSE
    SELECT a.start_time_local, a.duration_sec
    INTO v_arch_start, v_arch_duration
    FROM garmin_activity_archive a
    WHERE a.garmin_activity_id = v_garmin_activity_id
      AND a.training_log_id = v_keep_id;

    IF FOUND THEN
      UPDATE training_log k
      SET
        start_time = COALESCE(k.start_time, v_arch_start),
        end_time = COALESCE(
          k.end_time,
          v_arch_start + make_interval(secs => v_arch_duration::double precision)
        ),
        duration_min = COALESCE(k.duration_min, v_arch_duration / 60.0),
        updated_at = now()
      WHERE k.id = v_keep_id
        AND (k.start_time IS NULL OR k.end_time IS NULL);
    END IF;
  END IF;
END $$;

-- #28: align calories on linked garmin rows for this user (do not hand-edit keep)
SELECT apply_garmin_calories_to_training_log('77ea5bd6-e655-4f45-8143-40777562ace1'::uuid);
