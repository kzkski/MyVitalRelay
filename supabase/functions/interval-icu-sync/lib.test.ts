import {
  assertEquals,
  assertExists,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  basicAuthHeader,
  buildWellnessPayload,
  pickDailyMetrics,
  resolveAthleteId,
  resolveRequestStatus,
  shouldAttachLocalDate,
  shouldRetry,
  tokyoDateString,
  wellnessPutUrl,
} from "./lib.ts";

Deno.test("pickDailyMetrics ignores denied Connect even if earliest", () => {
  const metrics = pickDailyMetrics([
    {
      measured_at: "2026-09-10T15:10:10Z",
      weight_kg: 64.2,
      body_fat_pct: null,
      source_bundle_id: "com.garmin.connect.mobile",
    },
    {
      measured_at: "2026-09-11T00:39:08Z",
      weight_kg: 64.3,
      body_fat_pct: null,
      source_bundle_id: "com.oceanwing.z.smarthome",
    },
    {
      measured_at: "2026-09-11T00:39:08Z",
      weight_kg: null,
      body_fat_pct: 18.7,
      source_bundle_id: "com.oceanwing.z.smarthome",
    },
  ]);
  assertEquals(metrics.weight, 64.3);
  assertEquals(metrics.bodyFat, 18.7);
});

Deno.test("pickDailyMetrics all Connect yields empty", () => {
  assertEquals(
    pickDailyMetrics([
      {
        measured_at: "2026-09-10T15:10:10Z",
        weight_kg: 64.2,
        body_fat_pct: null,
        source_bundle_id: "com.garmin.connect.mobile",
      },
    ]),
    {},
  );
});

Deno.test("pickDailyMetrics missing source_bundle_id still considered", () => {
  const metrics = pickDailyMetrics([
    {
      measured_at: "2026-09-11T00:00:00Z",
      weight_kg: 65.0,
      body_fat_pct: null,
    },
  ]);
  assertEquals(metrics.weight, 65.0);
});

Deno.test("pickDailyMetrics picks earliest weight and bodyFat independently", () => {
  const metrics = pickDailyMetrics([
    {
      measured_at: "2026-07-27T01:00:00Z",
      weight_kg: 70.0,
      body_fat_pct: null,
    },
    {
      measured_at: "2026-07-27T08:00:00Z",
      weight_kg: null,
      body_fat_pct: 15.4,
    },
    {
      measured_at: "2026-07-27T03:00:00Z",
      weight_kg: 70.55,
      body_fat_pct: 14.0,
    },
  ]);
  assertEquals(metrics.weight, 70.0); // first weight at 01:00
  assertEquals(metrics.bodyFat, 14.0); // first bodyFat at 03:00 (before 08:00)
});

Deno.test("pickDailyMetrics empty", () => {
  assertEquals(pickDailyMetrics([]), {});
});

Deno.test("buildWellnessPayload", () => {
  assertEquals(buildWellnessPayload({}), null);
  assertEquals(buildWellnessPayload({ weight: 70 }), { weight: 70 });
  assertEquals(buildWellnessPayload({ bodyFat: 15 }), { bodyFat: 15 });
  assertEquals(buildWellnessPayload({ weight: 70, bodyFat: 15 }), {
    weight: 70,
    bodyFat: 15,
  });
});

Deno.test("shouldAttachLocalDate only for Tokyo today", () => {
  const fixed = new Date("2026-07-27T05:00:00Z"); // Asia/Tokyo 14:00
  assertEquals(tokyoDateString(fixed), "2026-07-27");
  assertEquals(shouldAttachLocalDate("2026-07-27", fixed), true);
  assertEquals(shouldAttachLocalDate("2026-07-26", fixed), false);
});

Deno.test("shouldRetry", () => {
  assertEquals(shouldRetry(500, 1, 2), true);
  assertEquals(shouldRetry(500, 2, 2), false);
  assertEquals(shouldRetry(401, 1, 2), false);
  assertEquals(shouldRetry(null, 1, 2), true);
});

Deno.test("resolveRequestStatus", () => {
  assertEquals(resolveRequestStatus(false, false, null).status, "partial");
  assertEquals(resolveRequestStatus(true, true, null).status, "complete");
  assertEquals(resolveRequestStatus(true, false, "boom").status, "failed");
});

Deno.test("resolveAthleteId defaults to 0", () => {
  assertEquals(resolveAthleteId({ supabase_user_id: "u", api_key: "k" }), "0");
  assertEquals(
    resolveAthleteId({ supabase_user_id: "u", api_key: "k", athlete_id: "i1" }),
    "i1",
  );
});

Deno.test("basicAuthHeader and wellnessPutUrl", () => {
  const header = basicAuthHeader("secret");
  assertExists(header.startsWith("Basic "));
  assertEquals(
    wellnessPutUrl("0", "2026-07-27", true),
    "https://intervals.icu/api/v1/athlete/0/wellness/2026-07-27?localDate=2026-07-27",
  );
  assertEquals(
    wellnessPutUrl("0", "2026-07-26", false),
    "https://intervals.icu/api/v1/athlete/0/wellness/2026-07-26",
  );
});
