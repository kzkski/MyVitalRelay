-- garmin_sync_request INSERT → Edge Function → GitHub repository_dispatch
-- 設計: docs/garmin-sync-ops.md §5

CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;

CREATE OR REPLACE FUNCTION public.notify_garmin_sync_dispatch()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  webhook_secret text;
  payload jsonb;
BEGIN
  IF NEW.status <> 'pending' OR NEW.trigger_source NOT IN ('healthkit', 'claude') THEN
    RETURN NEW;
  END IF;

  SELECT decrypted_secret INTO webhook_secret
  FROM vault.decrypted_secrets
  WHERE name = 'garmin_webhook_secret'
  LIMIT 1;

  payload := jsonb_build_object(
    'type', 'INSERT',
    'table', 'garmin_sync_request',
    'schema', 'public',
    'record', jsonb_build_object(
      'id', NEW.id,
      'status', NEW.status,
      'trigger_source', NEW.trigger_source
    )
  );

  PERFORM net.http_post(
    url := 'https://ykcbevvorckcigwwtftw.supabase.co/functions/v1/garmin-sync-dispatch',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'X-Garmin-Webhook-Secret', coalesce(webhook_secret, '')
    ),
    body := payload
  );

  RETURN NEW;
EXCEPTION
  WHEN OTHERS THEN
    RAISE WARNING 'garmin sync dispatch notify failed: %', SQLERRM;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS garmin_sync_request_notify_dispatch ON public.garmin_sync_request;
CREATE TRIGGER garmin_sync_request_notify_dispatch
  AFTER INSERT ON public.garmin_sync_request
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_garmin_sync_dispatch();
