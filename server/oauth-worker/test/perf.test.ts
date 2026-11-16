// Field performance reports (ADR 0034): only attested installs may send
// one, each is checked against a fixed schema, a day keeps at most 200 and
// 90 days are kept, and the summaries' arithmetic.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createWorker, type Env } from "../src/index.ts";
import { PERF_DAILY_LIMIT, PERF_RETENTION_DAYS } from "../src/objects.ts";
import { median, mergeBuckets, percentile, summarize, type PerfReport } from "../src/perf.ts";
import { attestEnv, b64, ecKeys, enc, makeAssertion, makeAttestation, makePki, RELEASE, TEAM, type Keys, type Launch } from "./helpers.ts";

const ORIGIN = "https://influx.bespokebits.dev";
const pki = await makePki();
const worker = createWorker({ roots: pki.roots });
const DAY_MS = 24 * 60 * 60 * 1000;
const day = (daysAgo = 0) => new Date(Date.now() - daysAgo * DAY_MS).toISOString().slice(0, 10);

const REPORT: PerfReport = {
  id: "0E3D6C1A-5B2F-4C8D-9A7E-1F2B3C4D5E6F",
  platform: "ios",
  build: "42",
  os: "27.2",
  device: "iPhone16,2",
  periodStart: "2026-11-12T00:00:00Z",
  periodEnd: "2026-11-13T00:00:00Z",
  scrollHitchMsPerS: 1.5,
  launch: [
    { startMs: 200, endMs: 210, count: 3 },
    { startMs: 300, endMs: 310, count: 1 },
  ],
  resume: [{ startMs: 50, endMs: 60, count: 2 }],
};

/** Sammy media counts as a report carries them. */
const MEDIA = {
  avatar: { grants: 40, grantsRateLimited: 1, bytesRateLimited: 0, heldBack: 3, deferred: 2 },
  attachment: { grants: 9, grantsRateLimited: 0, bytesRateLimited: 1, heldBack: 0, deferred: 0 },
};
const NO_MEDIA = { grants: 0, grantsRateLimited: 0, bytesRateLimited: 0, heldBack: 0, deferred: 0, direct: 0, fallbacks: 0 };
const NO_TIMES = { direct: [0, 0, 0, 0, 0, 0, 0], grant: [0, 0, 0, 0, 0, 0, 0] };
/** Counts as a build with direct loads sends them (ADR 0040). */
const DIRECT_MEDIA = {
  avatar: { ...MEDIA.avatar, direct: 120, fallbacks: 2 },
  attachment: { ...MEDIA.attachment, direct: 30, fallbacks: 1 },
  timeToImage: { direct: [50, 60, 20, 10, 5, 2, 1], grant: [0, 0, 1, 3, 4, 2, 1] },
};

/** REPORT as another payload: its own ID. */
const another = (changes: Partial<PerfReport> = {}): PerfReport => ({ ...REPORT, id: crypto.randomUUID().toUpperCase(), ...changes });

async function newChallenge(env: Env): Promise<string> {
  const response = await worker.fetch(new Request(`${ORIGIN}/oauth/challenge`, { method: "POST" }), env);
  assert.equal(response.status, 200);
  return ((await response.json()) as { challenge: string }).challenge;
}

type Key = { keyId: string; leaf: Keys; appId: string };

async function registered(env: Env): Promise<Key> {
  const challenge = await newChallenge(env);
  const made = await makeAttestation(pki, { challenge });
  const response = await worker.fetch(
    new Request(`${ORIGIN}/oauth/register`, {
      method: "POST",
      body: JSON.stringify({ platform: "ios", appId: RELEASE, keyId: b64(made.keyId), attestation: b64(made.attestation), challenge }),
    }),
    env,
  );
  assert.equal(response.status, 201);
  return { keyId: ((await response.json()) as { keyId: string }).keyId, leaf: made.leaf, appId: `${TEAM}.${RELEASE}` };
}

/** A report as the app sends one: a fresh challenge beside it, attested by `key` unless it is nil. */
async function reportRequest(env: Env, key: Key | undefined, counter: number, body: Record<string, unknown> = {}, launch: Launch = {}): Promise<Request> {
  const bytes = enc.encode(JSON.stringify({ challenge: await newChallenge(env), report: REPORT, ...body }));
  const headers: Record<string, string> = { "Content-Type": "application/json", "CF-Connecting-IP": "203.0.113.7" };
  if (key) {
    headers["X-Influx-Key"] = key.keyId;
    headers["X-Influx-Assertion"] = b64(await makeAssertion(key.leaf, bytes, counter, key.appId, launch));
  }
  return new Request(`${ORIGIN}/perf/report`, { method: "POST", headers, body: bytes });
}

async function read(env: Env, query = ""): Promise<Response> {
  return worker.fetch(new Request(`${ORIGIN}/perf/reports${query}`), env);
}

async function expectError(response: Response, status: number, code: string, label?: string) {
  assert.equal(response.status, status, label);
  assert.deepEqual(await response.json(), { error: code }, label);
}

function stored(perf: Awaited<ReturnType<typeof attestEnv>>["perf"], date = day()): Record<string, unknown>[] {
  return (perf.storage("reports").map.get(date) as Record<string, unknown>[] | undefined) ?? [];
}

test("an attested install's report is stored, with nothing about who sent it", async () => {
  const { env, perf } = await attestEnv();
  const key = await registered(env);
  const response = await worker.fetch(await reportRequest(env, key, 1), env);
  assert.equal(response.status, 204);
  const [kept] = stored(perf);
  const { receivedAt, ...report } = kept;
  assert.deepEqual(report, REPORT);
  assert.ok(Math.abs(Date.parse(receivedAt as string) - Date.now()) < 5000);
  // No address, key or assertion anywhere in what was kept.
  const text = JSON.stringify(perf.storage("reports").map.get(day()));
  for (const secret of ["203.0.113.7", key.keyId]) assert.ok(!text.includes(secret), secret);

  const answer = await read(env);
  assert.equal(answer.status, 200);
  assert.equal(answer.headers.get("Cache-Control"), "no-store");
  const { days, reports, summaries } = (await answer.json()) as { days: number; reports: unknown[]; summaries: unknown[] };
  assert.equal(days, 30);
  assert.deepEqual(reports, [kept]);
  assert.equal(summaries.length, 1);
});

test("a report without attestation, or with a forged one, is refused whatever REQUIRE_ATTESTATION says", async () => {
  for (const required of ["true", "false"]) {
    const { env, perf } = await attestEnv({ REQUIRE_ATTESTATION: required });
    const key = await registered(env);
    await expectError(await worker.fetch(await reportRequest(env, undefined, 1), env), 401, "attestation_required", required);
    // Without a challenge too: unattested is refused before anything else is asked of it.
    await expectError(await worker.fetch(await reportRequest(env, undefined, 1, { challenge: undefined }), env), 401, "attestation_required");
    // Another key signing for this key ID.
    await expectError(await worker.fetch(await reportRequest(env, { ...key, leaf: await ecKeys("P-256") }, 1), env), 401, "attestation_required");
    // One header without the other.
    const half = await reportRequest(env, key, 1);
    half.headers.delete("X-Influx-Assertion");
    await expectError(await worker.fetch(half, env), 401, "attestation_required");
    // A key never registered.
    await expectError(await worker.fetch(await reportRequest(env, { ...key, keyId: b64(new Uint8Array(32).fill(9)) }, 1), env), 401, "key_unknown");
    // A replayed report.
    const first = await reportRequest(env, key, 2);
    const replay = first.clone();
    assert.equal((await worker.fetch(first, env)).status, 204);
    await expectError(await worker.fetch(replay, env), 401, "attestation_required");
    assert.equal(stored(perf).length, 1, required);
  }
});

test("a genuine build the Worker doesn't accept is refused without stopping its sign-ins until attestation is required", async () => {
  const old: Launch = { bundleVersion: "0.0.9" };
  const optional = await attestEnv({ REQUIRE_ATTESTATION: "false" });
  const optionalKey = await registered(optional.env);
  await expectError(await worker.fetch(await reportRequest(optional.env, optionalKey, 1, {}, old), optional.env), 403, "report_not_accepted");
  const required = await attestEnv({ REQUIRE_ATTESTATION: "true" });
  const requiredKey = await registered(required.env);
  await expectError(await worker.fetch(await reportRequest(required.env, requiredKey, 1, {}, old), required.env), 403, "app_not_accepted");
  assert.equal(stored(optional.perf).length + stored(required.perf).length, 0);
});

test("a report outside the schema is refused before its challenge is spent", async () => {
  const { env, perf, challenges } = await attestEnv();
  const key = await registered(env);
  const bucket = { startMs: 0, endMs: 10, count: 1 };
  const bad: Record<string, unknown>[] = [
    { id: undefined },
    { id: "not-a-uuid" },
    { id: REPORT.id.toLowerCase() },
    { id: 7 },
    { platform: "android" },
    { platform: undefined },
    { build: "1.0-beta" },
    { build: "1".repeat(21) },
    { build: 42 },
    { os: "iOS 27" },
    { os: undefined },
    { device: "iPhone 16" },
    { device: "x".repeat(25) },
    { device: "" },
    { periodStart: "yesterday" },
    { periodStart: "2026-11-12" },
    { periodEnd: "2026-11-11T00:00:00Z" },
    { scrollHitchMsPerS: -1 },
    { scrollHitchMsPerS: 1000.5 },
    { scrollHitchMsPerS: "2" },
    { scrollHitchMsPerS: undefined },
    { launch: undefined },
    { launch: null },
    { launch: Array.from({ length: 25 }, () => bucket) },
    { launch: [{ ...bucket, startMs: 10 }] },
    { launch: [{ ...bucket, startMs: -1 }] },
    { launch: [{ ...bucket, endMs: 600_001 }] },
    { launch: [{ ...bucket, count: 1.5 }] },
    { launch: [{ ...bucket, count: 1_000_001 }] },
    { launch: [{ ...bucket, label: "cold" }] },
    { launch: [{ startMs: 0, endMs: 10 }] },
    { resume: null },
    { resume: [{ ...bucket, count: -1 }] },
    { sammyMedia: null },
    { sammyMedia: { avatar: MEDIA.avatar } },
    { sammyMedia: { ...MEDIA, video: MEDIA.avatar } },
    { sammyMedia: { ...MEDIA, avatar: { ...MEDIA.avatar, grants: -1 } } },
    { sammyMedia: { ...MEDIA, avatar: { ...MEDIA.avatar, grants: 1.5 } } },
    { sammyMedia: { ...MEDIA, avatar: { ...MEDIA.avatar, grants: 1_000_001 } } },
    { sammyMedia: { ...MEDIA, avatar: { ...MEDIA.avatar, grants: "3" } } },
    { sammyMedia: { ...MEDIA, attachment: { ...MEDIA.attachment, account: 1 } } },
    { sammyMedia: { ...MEDIA, attachment: { grants: 1 } } },
    // Both direct counts or neither, each a count; a time to image of exactly its buckets.
    { sammyMedia: { ...MEDIA, avatar: { ...MEDIA.avatar, direct: 1 } } },
    { sammyMedia: { ...DIRECT_MEDIA, avatar: { ...DIRECT_MEDIA.avatar, fallbacks: -1 } } },
    { sammyMedia: { ...DIRECT_MEDIA, attachment: { ...DIRECT_MEDIA.attachment, direct: 1_000_001 } } },
    { sammyMedia: { ...DIRECT_MEDIA, timeToImage: { direct: [1, 2, 3], grant: NO_TIMES.grant } } },
    { sammyMedia: { ...DIRECT_MEDIA, timeToImage: { direct: NO_TIMES.direct } } },
    { sammyMedia: { ...DIRECT_MEDIA, timeToImage: { ...NO_TIMES, other: NO_TIMES.grant } } },
    { sammyMedia: { ...DIRECT_MEDIA, timeToImage: { ...NO_TIMES, grant: [0, 0, 0, 0, 0, 0, 1.5] } } },
    { sammyMedia: { ...DIRECT_MEDIA, timeToImage: null } },
    { extra: true },
  ];
  let counter = 1;
  for (const change of bad) {
    const challenge = await newChallenge(env);
    const report = Object.fromEntries(Object.entries({ ...REPORT, ...change }).filter(([, value]) => value !== undefined));
    const response = await worker.fetch(await reportRequest(env, key, counter++, { challenge, report }), env);
    await expectError(response, 400, "invalid_report", JSON.stringify(change));
    assert.ok(challenges.storage("challenges").map.has(challenge), JSON.stringify(change));
  }
  await expectError(await worker.fetch(await reportRequest(env, key, counter++, { report: "fast" }), env), 400, "invalid_report");
  await expectError(await worker.fetch(await reportRequest(env, key, counter++, { extra: 1 }), env), 400, "invalid_request");
  // At the bounds, and without the optional resume, it's taken.
  const edge = { ...REPORT, scrollHitchMsPerS: null, build: "1.2.3", os: "27", launch: Array.from({ length: 24 }, () => ({ startMs: 0, endMs: 600_000, count: 1_000_000 })) };
  delete (edge as Partial<PerfReport>).resume;
  assert.equal((await worker.fetch(await reportRequest(env, key, counter++, { report: edge }), env)).status, 204);
  assert.equal(stored(perf).length, 1);
  // Sammy media counts at their bound are taken and stored as sent.
  const counted = { ...REPORT, id: "00000000-0000-4000-8000-00000000000A", sammyMedia: { ...MEDIA, attachment: { ...MEDIA.attachment, heldBack: 1_000_000 } } };
  assert.equal((await worker.fetch(await reportRequest(env, key, counter++, { report: counted }), env)).status, 204);
  assert.deepEqual(stored(perf).find((report) => report.id === counted.id)?.sammyMedia, counted.sammyMedia);
  // So are a build's direct counts and time to image, and a build before them is still taken.
  const direct = { ...REPORT, id: "00000000-0000-4000-8000-00000000000B", sammyMedia: DIRECT_MEDIA };
  assert.equal((await worker.fetch(await reportRequest(env, key, counter++, { report: direct }), env)).status, 204);
  assert.deepEqual(stored(perf).find((report) => report.id === direct.id)?.sammyMedia, DIRECT_MEDIA);
});

test("a day keeps at most 200 reports", async () => {
  const { env, perf } = await attestEnv();
  const key = await registered(env);
  const today = day();
  perf.storage("reports").map.set(today, Array.from({ length: PERF_DAILY_LIMIT - 1 }, () => ({ ...REPORT, receivedAt: "x" })));
  assert.equal((await worker.fetch(await reportRequest(env, key, 1), env)).status, 204);
  assert.equal(stored(perf).length, PERF_DAILY_LIMIT);
  const full = await worker.fetch(await reportRequest(env, key, 2, { report: another() }), env);
  await expectError(full, 503, "daily_limit");
  assert.equal(stored(perf).length, PERF_DAILY_LIMIT);
});

test("a report sent again, as after a lost answer, is stored once", async () => {
  const { env, perf } = await attestEnv();
  const key = await registered(env);
  // The report and its name go in one write, all or nothing.
  const backing = perf.storage("reports");
  const put = backing.put;
  const writes: string[][] = [];
  backing.put = async (entries: string | Record<string, unknown>, value?: unknown) => {
    writes.push(typeof entries === "string" ? [entries] : Object.keys(entries).sort());
    return put(entries, value);
  };
  assert.equal((await worker.fetch(await reportRequest(env, key, 1), env)).status, 204);
  assert.deepEqual(writes, [[day(), `seen:${REPORT.id}`]]);
  // A fresh challenge and assertion, the same report.
  assert.equal((await worker.fetch(await reportRequest(env, key, 2), env)).status, 204);
  assert.equal(stored(perf).length, 1);
  // Another install's report of the same model, build and period is its own.
  assert.equal((await worker.fetch(await reportRequest(env, key, 3, { report: another() }), env)).status, 204);
  assert.equal(stored(perf).length, 2);
  // Even on a later day.
  const storage = perf.storage("reports").map;
  storage.set(day(3), storage.get(day()));
  storage.delete(day());
  assert.equal((await worker.fetch(await reportRequest(env, key, 4), env)).status, 204);
  assert.equal(stored(perf).length, 0);
});

test("reports are kept 90 days, and read back newest first for the days asked", async () => {
  const { env, perf } = await attestEnv();
  const key = await registered(env);
  const storage = perf.storage("reports").map;
  const at = (build: string) => ({ ...REPORT, build, receivedAt: "x" });
  storage.set(day(PERF_RETENTION_DAYS), [at("1")]);
  storage.set(day(PERF_RETENTION_DAYS + 30), [at("1")]);
  storage.set(day(PERF_RETENTION_DAYS - 1), [at("2")]);
  storage.set(day(10), [at("3"), at("4")]);
  storage.set("seen:old", day(PERF_RETENTION_DAYS));
  storage.set("seen:kept", day(PERF_RETENTION_DAYS - 1));
  // A new day's first report clears every day before the last 90, and the
  // names of the reports it held.
  assert.equal((await worker.fetch(await reportRequest(env, key, 1), env)).status, 204);
  const seen = `seen:${REPORT.id}`;
  assert.deepEqual([...storage.keys()].sort(), [day(PERF_RETENTION_DAYS - 1), day(10), day(), "seen:kept", seen].sort());

  const builds = async (query: string) => ((await (await read(env, query)).json()) as { reports: { build: string }[] }).reports.map((r) => r.build);
  assert.deepEqual(await builds("?days=90"), ["42", "4", "3", "2"]);
  assert.deepEqual(await builds("?days=11"), ["42", "4", "3"]);
  assert.deepEqual(await builds("?days=10"), ["42"]);
  assert.deepEqual(await builds(""), ["42", "4", "3"]);
  for (const query of ["?days=0", "?days=91", "?days=-1", "?days=1.5", "?days=ten", "?days=", "?days=100"]) {
    await expectError(await read(env, query), 400, "invalid_days", query);
  }
  // Reading changes nothing.
  assert.deepEqual([...storage.keys()].sort(), [day(PERF_RETENTION_DAYS - 1), day(10), day(), "seen:kept", seen].sort());

  // A full day ageing out is more keys than one delete takes.
  storage.set(day(PERF_RETENTION_DAYS), Array.from({ length: PERF_DAILY_LIMIT }, () => at("1")));
  for (let n = 0; n < PERF_DAILY_LIMIT; n++) storage.set(`seen:old-${n}`, day(PERF_RETENTION_DAYS));
  storage.delete(day());
  assert.equal((await worker.fetch(await reportRequest(env, key, 2, { report: another() }), env)).status, 204);
  assert.ok(![...storage.keys()].some((name) => name.startsWith("seen:old-") || name === day(PERF_RETENTION_DAYS)));
  assert.equal(stored(perf).length, 1);
});

test("a daily alarm removes reports past 90 days when no new report comes", async () => {
  const { env, perf } = await attestEnv();
  const key = await registered(env);
  const reports = perf.storage("reports");
  const at = (build: string) => ({ ...REPORT, build, receivedAt: "x" });
  assert.equal((await worker.fetch(await reportRequest(env, key, 1), env)).status, 204);
  // A stored report sets the alarm early in the next UTC day.
  const tomorrow = (Math.floor(Date.now() / DAY_MS) + 1) * DAY_MS;
  assert.ok(reports.alarm.at !== null && reports.alarm.at > tomorrow && reports.alarm.at < tomorrow + 60 * 60 * 1000);
  // Reports stop; days age out with no report to clear them.
  reports.map.set(day(PERF_RETENTION_DAYS), [at("old")]);
  reports.map.set("seen:old", day(PERF_RETENTION_DAYS));
  await perf.fireAlarm("reports");
  const seen = `seen:${REPORT.id}`;
  assert.deepEqual([...reports.map.keys()].sort(), [day(), seen].sort());
  assert.ok(reports.alarm.at !== null, "it comes again while reports are kept");
  // Once nothing is kept, it stops.
  reports.map.clear();
  await perf.fireAlarm("reports");
  assert.equal(reports.alarm.at, null);
});

test("only POST sends a report and only GET reads them, each rate limited", async () => {
  const { env } = await attestEnv();
  await expectError(await worker.fetch(new Request(`${ORIGIN}/perf/report`), env), 405, "method_not_allowed");
  await expectError(await worker.fetch(new Request(`${ORIGIN}/perf/reports`, { method: "POST" }), env), 405, "method_not_allowed");
  const limited = { ...env, RATE_LIMITER: { limit: async () => ({ success: false }) } };
  await expectError(await worker.fetch(await reportRequest(env, undefined, 1), limited), 429, "rate_limited");
  await expectError(await read(limited), 429, "rate_limited");
  await expectError(await worker.fetch(new Request(`${ORIGIN}/perf/report`, { method: "POST", body: "[]" }), env), 400, "invalid_request");
});

// Summaries

test("median and percentiles", () => {
  assert.equal(median([]), null);
  assert.equal(median([3]), 3);
  assert.equal(median([5, 1, 3]), 3);
  assert.equal(median([4, 1, 3, 2]), 2.5);

  // Ten launches: 0–100 ms holds 4, 100–200 ms holds 4, 200–400 ms holds 2.
  const histogram = [
    { startMs: 0, endMs: 100, count: 4 },
    { startMs: 100, endMs: 200, count: 4 },
    { startMs: 200, endMs: 400, count: 2 },
  ];
  // The 5th of 10 lies a quarter into the second bucket.
  assert.equal(percentile(histogram, 0.5), 125);
  // The 9th lies halfway into the third.
  assert.equal(percentile(histogram, 0.9), 300);
  assert.equal(percentile(histogram, 1), 400);
  assert.equal(percentile([], 0.5), null);
  assert.equal(percentile([{ startMs: 0, endMs: 10, count: 0 }], 0.5), null);
  // Empty buckets are passed over.
  assert.equal(percentile([{ startMs: 0, endMs: 10, count: 0 }, { startMs: 10, endMs: 20, count: 2 }], 0.5), 15);
  // Overlapping buckets, as two reports merged differently give: one launch
  // spread over 0–600 ms and one at 299–300 ms put the middle near 300 ms.
  const overlapping = [
    { startMs: 0, endMs: 600, count: 1 },
    { startMs: 299, endMs: 300, count: 1 },
  ];
  const middle = percentile(overlapping, 0.5)!;
  assert.ok(middle > 299 && middle < 300, String(middle));
  // A wide bucket over two narrow ones: 0–400 holds 4, 0–100 and 100–200
  // hold 2 each. Below 100 lie 1 + 2 = 3, below 200 lie 2 + 4 = 6, so the
  // 4th of 8 is a third of the way from 100 to 200.
  assert.equal(percentile([{ startMs: 0, endMs: 400, count: 4 }, { startMs: 0, endMs: 100, count: 2 }, { startMs: 100, endMs: 200, count: 2 }], 0.5), 100 + 100 / 3);
  // Not rounded: the bar is compared with the figure itself.
  assert.equal(percentile([{ startMs: 0, endMs: 10, count: 3 }], 1 / 3), 10 / 3);
  assert.equal(percentile([{ startMs: 299, endMs: 300, count: 10_000 }], 0.9996), 299.9996);

  assert.deepEqual(
    mergeBuckets([
      [{ startMs: 100, endMs: 200, count: 1 }, { startMs: 0, endMs: 100, count: 2 }],
      [{ startMs: 0, endMs: 100, count: 3 }],
    ]),
    [
      { startMs: 0, endMs: 100, count: 5 },
      { startMs: 100, endMs: 200, count: 1 },
    ],
  );
});

test("summaries group by platform and build, merging histograms", () => {
  const { resume: _, ...base } = REPORT;
  const report = (platform: "ios" | "mac", build: string, hitch: number | null, launch: PerfReport["launch"], resume?: PerfReport["resume"]): PerfReport => ({
    ...base,
    platform,
    build,
    scrollHitchMsPerS: hitch,
    launch,
    ...(resume ? { resume } : {}),
  });
  const summaries = summarize([
    report("mac", "41", null, [{ startMs: 400, endMs: 500, count: 1 }]),
    report("ios", "9", 7, [{ startMs: 0, endMs: 100, count: 1 }]),
    report("ios", "10", 2, [{ startMs: 0, endMs: 100, count: 4 }], [{ startMs: 0, endMs: 20, count: 2 }]),
    report("ios", "10", 6, [{ startMs: 100, endMs: 200, count: 4 }]),
    report("ios", "10", null, [{ startMs: 200, endMs: 400, count: 2 }]),
    report("ios", "10", 3.1234, []),
  ]);
  assert.deepEqual(
    summaries.map((s) => `${s.platform} ${s.build}`),
    ["ios 10", "ios 9", "mac 41"],
  );
  const [ten, nine, mac] = summaries;
  assert.equal(ten.reports, 4);
  // Three measured scrolling: 2, 3.1234 and 6.
  assert.deepEqual(ten.scrollHitchMsPerS, { reports: 3, median: 3.1234, worst: 6 });
  // Ten launches over three reports' histograms, as in the percentile test;
  // the fourth report counted none.
  assert.deepEqual(ten.launch, { reports: 3, count: 10, p50Ms: 125, p90Ms: 300 });
  assert.deepEqual(ten.resume, { reports: 1, count: 2, p50Ms: 10, p90Ms: 18 });
  assert.deepEqual(nine.scrollHitchMsPerS, { reports: 1, median: 7, worst: 7 });
  assert.deepEqual(mac.scrollHitchMsPerS, { reports: 0, median: null, worst: null });
  assert.deepEqual(mac.resume, { reports: 0, count: 0, p50Ms: null, p90Ms: null });
  assert.deepEqual(mac.launch, { reports: 1, count: 1, p50Ms: 450, p90Ms: 490 });
  assert.deepEqual(ten.scrollHitchByDevice, [{ device: "iPhone16,2", reports: 3, median: 3.1234, worst: 6 }]);
  // Hitches per hardware model, as well as for the build.
  const mixed = summarize([
    { ...base, device: "iPhone17,2", scrollHitchMsPerS: 1 },
    { ...base, device: "iPhone16,2", scrollHitchMsPerS: 8 },
    { ...base, device: "iPhone17,2", scrollHitchMsPerS: 2 },
    { ...base, device: "iPhone16,2", scrollHitchMsPerS: null },
  ]);
  assert.deepEqual(mixed[0].scrollHitchMsPerS, { reports: 3, median: 2, worst: 8 });
  assert.deepEqual(mixed[0].scrollHitchByDevice, [
    { device: "iPhone16,2", reports: 1, median: 8, worst: 8 },
    { device: "iPhone17,2", reports: 2, median: 1.5, worst: 2 },
  ]);
  // Sammy media counts add up over the reports that carried them.
  assert.deepEqual(ten.sammyMedia, { reports: 0, avatar: NO_MEDIA, attachment: NO_MEDIA, timeToImage: NO_TIMES });
  const media = summarize([
    { ...base, sammyMedia: MEDIA },
    { ...base, sammyMedia: { avatar: { ...MEDIA.avatar, deferred: 5 }, attachment: MEDIA.attachment } },
    { ...base, sammyMedia: DIRECT_MEDIA },
    { ...base },
  ]);
  // A report from a build before direct loads adds nothing to their counts.
  assert.deepEqual(media[0].sammyMedia, {
    reports: 3,
    avatar: { grants: 120, grantsRateLimited: 3, bytesRateLimited: 0, heldBack: 9, deferred: 9, direct: 120, fallbacks: 2 },
    attachment: { grants: 27, grantsRateLimited: 0, bytesRateLimited: 3, heldBack: 0, deferred: 0, direct: 30, fallbacks: 1 },
    timeToImage: DIRECT_MEDIA.timeToImage,
  });
  // A histogram whose buckets all count nothing is no evidence.
  const empty = summarize([report("ios", "8", null, [{ startMs: 0, endMs: 10, count: 0 }])]);
  assert.deepEqual(empty[0].launch, { reports: 0, count: 0, p50Ms: null, p90Ms: null });
});
