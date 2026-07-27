/**
 * Intervals.icu wellness sync (weight + bodyFat).
 * Hot path: pg_net webhook → claim → PUT (no GitHub Actions).
 * Modes: webhook (single id), { force: true, request_id }, { sweep: true }.
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";
import {
  basicAuthHeader,
  buildWellnessPayload,
  findSyncUser,
  parseSyncUsers,
  pickDailyMetrics,
  resolveAthleteId,
  resolveRequestStatus,
  shouldAttachLocalDate,
  shouldRetry,
  wellnessPutUrl,
  type BodySample,
  type SyncUser,
  type WellnessPayload,
} from "./lib.ts";

const WEBHOOK_SECRET = Deno.env.get("INTERVAL_ICU_WEBHOOK_SECRET");
const SWEEP_LIMIT = 20;

type SyncRequestRow = {
  id: string;
  user_id: string;
  date: string;
  status: string;
};

function jsonResponse(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function unauthorized(): Response {
  return jsonResponse({ error: "unauthorized" }, 401);
}

function adminClient(): SupabaseClient {
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) {
    throw new Error("SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY missing");
  }
  return createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

function loadUsers(): SyncUser[] {
  return parseSyncUsers(Deno.env.get("INTERVAL_ICU_SYNC_USERS"));
}

function authorize(req: Request): boolean {
  if (!WEBHOOK_SECRET) return true;
  return req.headers.get("x-interval-icu-webhook-secret") === WEBHOOK_SECRET;
}

async function selfHeal(sb: SupabaseClient): Promise<void> {
  await sb.rpc("reset_stale_interval_icu_sync_requests", { stale_minutes: 15 });
  await sb.rpc("expire_old_pending_interval_icu_sync_requests", {
    max_age_hours: 24,
  });
}

async function claimRequest(
  sb: SupabaseClient,
  id: string,
  allowFailed: boolean,
): Promise<SyncRequestRow | null> {
  const statuses = allowFailed ? ["pending", "failed"] : ["pending"];
  const { data, error } = await sb
    .from("interval_icu_sync_request")
    .update({
      status: "running",
      started_at: new Date().toISOString(),
      error_message: null,
    })
    .eq("id", id)
    .in("status", statuses)
    .select("id,user_id,date,status")
    .maybeSingle();

  if (error) {
    console.error("claim failed", id, error.message);
    return null;
  }
  return data as SyncRequestRow | null;
}

async function finishRequest(
  sb: SupabaseClient,
  id: string,
  status: "complete" | "partial" | "failed",
  errorMessage: string | null,
): Promise<void> {
  const { error } = await sb
    .from("interval_icu_sync_request")
    .update({
      status,
      completed_at: new Date().toISOString(),
      error_message: errorMessage,
    })
    .eq("id", id);
  if (error) {
    console.error("finish failed", id, error.message);
  }
}

async function loadDaySamples(
  sb: SupabaseClient,
  userId: string,
  date: string,
): Promise<BodySample[]> {
  const { data, error } = await sb
    .from("body_composition_sample")
    .select("measured_at,weight_kg,body_fat_pct")
    .eq("user_id", userId)
    .eq("date", date);

  if (error) {
    throw new Error(`sample query failed: ${error.message}`);
  }
  return (data ?? []) as BodySample[];
}

async function putWellness(
  user: SyncUser,
  date: string,
  payload: WellnessPayload,
): Promise<{ ok: boolean; status: number | null; detail: string }> {
  const athleteId = resolveAthleteId(user);
  const url = wellnessPutUrl(athleteId, date, shouldAttachLocalDate(date));
  const maxAttempts = 2;

  let lastStatus: number | null = null;
  let lastDetail = "";

  for (let attempt = 0; attempt < maxAttempts; attempt++) {
    try {
      const res = await fetch(url, {
        method: "PUT",
        headers: {
          Authorization: basicAuthHeader(user.api_key),
          "Content-Type": "application/json",
          Accept: "application/json",
        },
        body: JSON.stringify(payload),
      });
      lastStatus = res.status;
      lastDetail = await res.text();
      if (res.ok) {
        return { ok: true, status: res.status, detail: lastDetail };
      }
      if (!shouldRetry(res.status, attempt + 1, maxAttempts)) {
        break;
      }
    } catch (err) {
      lastStatus = null;
      lastDetail = err instanceof Error ? err.message : String(err);
      if (!shouldRetry(null, attempt + 1, maxAttempts)) {
        break;
      }
    }
    await new Promise((r) => setTimeout(r, 500 * (attempt + 1)));
  }

  return { ok: false, status: lastStatus, detail: lastDetail.slice(0, 500) };
}

async function processClaimed(
  sb: SupabaseClient,
  row: SyncRequestRow,
  users: SyncUser[],
): Promise<{ id: string; status: string }> {
  const user = findSyncUser(users, row.user_id);
  if (!user?.api_key) {
    await finishRequest(
      sb,
      row.id,
      "failed",
      "no INTERVAL_ICU_SYNC_USERS entry for user",
    );
    return { id: row.id, status: "failed" };
  }

  let samples: BodySample[];
  try {
    samples = await loadDaySamples(sb, row.user_id, row.date);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    await finishRequest(sb, row.id, "failed", msg);
    return { id: row.id, status: "failed" };
  }

  const metrics = pickDailyMetrics(samples);
  const payload = buildWellnessPayload(metrics);
  if (!payload) {
    const resolved = resolveRequestStatus(false, false, null);
    await finishRequest(sb, row.id, resolved.status, resolved.errorMessage);
    return { id: row.id, status: resolved.status };
  }

  const put = await putWellness(user, row.date, payload);
  const resolved = resolveRequestStatus(
    true,
    put.ok,
    put.ok ? null : `HTTP ${put.status}: ${put.detail}`,
  );
  await finishRequest(sb, row.id, resolved.status, resolved.errorMessage);
  return { id: row.id, status: resolved.status };
}

async function processById(
  sb: SupabaseClient,
  users: SyncUser[],
  id: string,
  allowFailed: boolean,
): Promise<{ id: string; status: string } | { id: string; skipped: string }> {
  const claimed = await claimRequest(sb, id, allowFailed);
  if (!claimed) {
    return { id, skipped: "not claimable" };
  }
  return await processClaimed(sb, claimed, users);
}

async function sweep(
  sb: SupabaseClient,
  users: SyncUser[],
  limit = SWEEP_LIMIT,
): Promise<Array<{ id: string; status: string } | { id: string; skipped: string }>> {
  const { data, error } = await sb
    .from("interval_icu_sync_request")
    .select("id")
    .eq("status", "pending")
    .order("date", { ascending: true })
    .limit(limit);

  if (error) {
    throw new Error(`sweep query failed: ${error.message}`);
  }

  const results = [];
  for (const row of data ?? []) {
    results.push(await processById(sb, users, row.id as string, false));
  }
  return results;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return jsonResponse({ error: "method not allowed" }, 405);
  }
  if (!authorize(req)) {
    return unauthorized();
  }

  let body: Record<string, unknown> = {};
  try {
    body = (await req.json()) as Record<string, unknown>;
  } catch {
    return jsonResponse({ error: "invalid json" }, 400);
  }

  let sb: SupabaseClient;
  let users: SyncUser[];
  try {
    sb = adminClient();
    users = loadUsers();
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(msg);
    return jsonResponse({ error: msg }, 500);
  }

  await selfHeal(sb);

  // Mode: sweep
  if (body.sweep === true) {
    try {
      const results = await sweep(sb, users);
      return jsonResponse({ mode: "sweep", results });
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      return jsonResponse({ error: msg }, 500);
    }
  }

  // Mode: force retry by id
  if (body.force === true && typeof body.request_id === "string") {
    const result = await processById(sb, users, body.request_id, true);
    return jsonResponse({ mode: "force", result });
  }

  // Mode: webhook INSERT payload
  const table = body.table;
  const type = body.type;
  const record = body.record as { id?: string; status?: string } | null;

  if (table && table !== "interval_icu_sync_request") {
    return jsonResponse({ skipped: true, reason: "irrelevant table" });
  }
  if (type && type !== "INSERT") {
    return jsonResponse({ skipped: true, reason: "not insert" });
  }
  if (!record?.id) {
    // Also allow { request_id } shorthand
    if (typeof body.request_id === "string") {
      const result = await processById(sb, users, body.request_id, false);
      return jsonResponse({ mode: "request_id", result });
    }
    return jsonResponse({ error: "missing record.id" }, 400);
  }
  if (record.status && record.status !== "pending") {
    return jsonResponse({ skipped: true, reason: "not pending" });
  }

  const result = await processById(sb, users, record.id, false);
  return jsonResponse({ mode: "webhook", result });
});
