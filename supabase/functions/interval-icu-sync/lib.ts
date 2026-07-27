/** Pure helpers for interval-icu-sync Edge Function (Issue #24). */

export type BodySample = {
  measured_at: string;
  weight_kg: number | null;
  body_fat_pct: number | null;
};

export type DailyMetrics = {
  weight?: number;
  bodyFat?: number;
};

export type WellnessPayload = {
  weight?: number;
  bodyFat?: number;
};

/** Round to 1 decimal place to match numeric(4,1). */
export function round1(value: number): number {
  return Math.round(value * 10) / 10;
}

/**
 * Pick independent latest weight and body-fat for a calendar day.
 * Weight and body fat may live on different HealthKit sample rows.
 */
export function pickDailyMetrics(samples: BodySample[]): DailyMetrics {
  let latestWeight: { at: string; value: number } | null = null;
  let latestBodyFat: { at: string; value: number } | null = null;

  for (const sample of samples) {
    if (sample.weight_kg != null && Number.isFinite(sample.weight_kg)) {
      if (!latestWeight || sample.measured_at > latestWeight.at) {
        latestWeight = { at: sample.measured_at, value: sample.weight_kg };
      }
    }
    if (sample.body_fat_pct != null && Number.isFinite(sample.body_fat_pct)) {
      if (!latestBodyFat || sample.measured_at > latestBodyFat.at) {
        latestBodyFat = { at: sample.measured_at, value: sample.body_fat_pct };
      }
    }
  }

  const out: DailyMetrics = {};
  if (latestWeight) out.weight = round1(latestWeight.value);
  if (latestBodyFat) out.bodyFat = round1(latestBodyFat.value);
  return out;
}

export function buildWellnessPayload(metrics: DailyMetrics): WellnessPayload | null {
  if (metrics.weight == null && metrics.bodyFat == null) return null;
  const payload: WellnessPayload = {};
  if (metrics.weight != null) payload.weight = metrics.weight;
  if (metrics.bodyFat != null) payload.bodyFat = metrics.bodyFat;
  return payload;
}

/** YYYY-MM-DD in Asia/Tokyo. */
export function tokyoDateString(now: Date = new Date()): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: "Asia/Tokyo",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(now);
}

/** Attach localDate only for today's wellness PUT (updates settings current weight). */
export function shouldAttachLocalDate(
  dateStr: string,
  now: Date = new Date(),
): boolean {
  return dateStr === tokyoDateString(now);
}

export function shouldRetry(
  statusCode: number | null,
  attempt: number,
  maxAttempts = 2,
): boolean {
  if (attempt >= maxAttempts) return false;
  if (statusCode == null) return true; // network error
  return statusCode >= 500;
}

export function resolveRequestStatus(
  hasMetrics: boolean,
  putSucceeded: boolean,
  error: string | null,
): { status: "complete" | "partial" | "failed"; errorMessage: string | null } {
  if (!hasMetrics) {
    return { status: "partial", errorMessage: error ?? "no weight/bodyFat sample" };
  }
  if (putSucceeded) {
    return { status: "complete", errorMessage: null };
  }
  return { status: "failed", errorMessage: error ?? "put failed" };
}

export type SyncUser = {
  supabase_user_id: string;
  api_key: string;
  athlete_id?: string;
};

export function parseSyncUsers(raw: string | undefined): SyncUser[] {
  if (!raw?.trim()) return [];
  const parsed = JSON.parse(raw) as SyncUser[];
  if (!Array.isArray(parsed)) {
    throw new Error("INTERVAL_ICU_SYNC_USERS must be a JSON array");
  }
  return parsed;
}

export function resolveAthleteId(user: SyncUser): string {
  const id = user.athlete_id?.trim();
  return id && id.length > 0 ? id : "0";
}

export function findSyncUser(
  users: SyncUser[],
  supabaseUserId: string,
): SyncUser | undefined {
  return users.find((u) => u.supabase_user_id === supabaseUserId);
}

export function basicAuthHeader(apiKey: string): string {
  return `Basic ${btoa(`API_KEY:${apiKey}`)}`;
}

export function wellnessPutUrl(
  athleteId: string,
  date: string,
  attachLocalDate: boolean,
): string {
  const base =
    `https://intervals.icu/api/v1/athlete/${encodeURIComponent(athleteId)}/wellness/${date}`;
  return attachLocalDate ? `${base}?localDate=${date}` : base;
}
