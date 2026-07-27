-- interval_icu_sync_request INSERT → Edge Function（直接 claim + PUT）
-- 設計: docs/interval-icu-sync-ops.md

CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;

CREATE OR REPLACE FUNCTION public.notify_interval_icu_sync_dispatch()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  webhook_secret text;
  payload jsonb;
BEGIN
  IF NEW.status <> 'pending' THEN
    RETURN NEW;
  END IF;

  SELECT decrypted_secret INTO webhook_secret
  FROM vault.decrypted_secrets
  WHERE name = 'interval_icu_webhook_secret'
  LIMIT 1;

  payload := jsonb_build_object(
    'type', 'INSERT',
    'table', 'interval_icu_sync_request',
    'schema', 'public',
    'record', jsonb_build_object(
      'id', NEW.id,
      'status', NEW.status,
      'date', NEW.date
    )
  );

  PERFORM net.http_post(
    url := 'https://ykcbevvorckcigwwtftw.supabase.co/functions/v1/interval-icu-sync',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'X-Interval-Icu-Webhook-Secret', coalesce(webhook_secret, '')
    ),
    body := payload
  );

  RETURN NEW;
EXCEPTION
  WHEN OTHERS THEN
    RAISE WARNING 'interval icu sync dispatch notify failed: %', SQLERRM;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS interval_icu_sync_request_notify_dispatch ON public.interval_icu_sync_request;
CREATE TRIGGER interval_icu_sync_request_notify_dispatch
  AFTER INSERT ON public.interval_icu_sync_request
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_interval_icu_sync_dispatch();
