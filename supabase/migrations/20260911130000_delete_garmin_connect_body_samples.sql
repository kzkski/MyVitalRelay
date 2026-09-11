-- Issue #38: Garmin Connect Mobile 由来の汚染 body_composition_sample を削除する。
-- 承認済み（75 行, source_bundle_id = com.garmin.connect.mobile）。
-- 冪等: 2 回目は 0 行。Eufy / Omron は対象外。
-- 削除後、2026-09-11 を Intervals.icu へ再投入する（Connect が earliest を取っていた日）。

DELETE FROM public.body_composition_sample
WHERE source_bundle_id = 'com.garmin.connect.mobile';

INSERT INTO public.interval_icu_sync_request (user_id, date, trigger_source)
SELECT
  '77ea5bd6-e655-4f45-8143-40777562ace1'::uuid,
  DATE '2026-09-11',
  'manual'
WHERE NOT EXISTS (
  SELECT 1
  FROM public.interval_icu_sync_request r
  WHERE r.user_id = '77ea5bd6-e655-4f45-8143-40777562ace1'
    AND r.date = DATE '2026-09-11'
    AND r.status = 'pending'
);
