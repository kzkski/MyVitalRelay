import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const GITHUB_REPO = Deno.env.get("GITHUB_REPO") ?? "kzkski/MyVitalRelay";
const GITHUB_DISPATCH_TOKEN = Deno.env.get("GITHUB_DISPATCH_TOKEN");
const WEBHOOK_SECRET = Deno.env.get("GARMIN_WEBHOOK_SECRET");

const DISPATCH_SOURCES = new Set(["healthkit", "claude"]);

interface WebhookPayload {
  type: "INSERT" | "UPDATE" | "DELETE";
  table: string;
  schema: string;
  record: {
    id: string;
    status: string;
    trigger_source?: string;
  } | null;
}

function jsonResponse(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function unauthorized(): Response {
  return jsonResponse({ error: "unauthorized" }, 401);
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return jsonResponse({ error: "method not allowed" }, 405);
  }

  if (!GITHUB_DISPATCH_TOKEN) {
    console.error("GITHUB_DISPATCH_TOKEN is not configured");
    return jsonResponse({ error: "dispatch token not configured" }, 500);
  }

  if (WEBHOOK_SECRET) {
    const provided = req.headers.get("x-garmin-webhook-secret");
    if (provided !== WEBHOOK_SECRET) {
      return unauthorized();
    }
  }

  let payload: WebhookPayload;
  try {
    payload = (await req.json()) as WebhookPayload;
  } catch {
    return jsonResponse({ error: "invalid json" }, 400);
  }

  if (payload.schema !== "public" || payload.table !== "garmin_sync_request") {
    return jsonResponse({ skipped: true, reason: "irrelevant table" });
  }

  if (payload.type !== "INSERT") {
    return jsonResponse({ skipped: true, reason: "not insert" });
  }

  const record = payload.record;
  if (!record) {
    return jsonResponse({ skipped: true, reason: "missing record" });
  }

  if (record.status !== "pending") {
    return jsonResponse({ skipped: true, reason: "not pending" });
  }

  const source = record.trigger_source ?? "claude";
  if (!DISPATCH_SOURCES.has(source)) {
    return jsonResponse({
      skipped: true,
      reason: "trigger_source not dispatched",
      trigger_source: source,
    });
  }

  const ghRes = await fetch(
    `https://api.github.com/repos/${GITHUB_REPO}/dispatches`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${GITHUB_DISPATCH_TOKEN}`,
        Accept: "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "Content-Type": "application/json",
        "User-Agent": "MyVitalRelay-garmin-sync-dispatch",
      },
      body: JSON.stringify({
        event_type: "garmin-sync",
        client_payload: { request_id: record.id },
      }),
    },
  );

  if (!ghRes.ok) {
    const detail = await ghRes.text();
    console.error("GitHub repository_dispatch failed", ghRes.status, detail);
    return jsonResponse(
      { error: "github dispatch failed", status: ghRes.status, detail },
      502,
    );
  }

  return jsonResponse(
    { dispatched: true, request_id: record.id, trigger_source: source },
    202,
  );
});
