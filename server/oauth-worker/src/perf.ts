// Field performance reports (ADR 0034): TestFlight installs send the
// MetricKit figures each day's payload carries, attested with App Attest, and
// the maintainer reads them back per build against the bar (under 5 ms/s of
// scroll hitches, under 300 ms to the first draw). A report holds the build,
// the OS, the hardware model and the figures; nothing about the caller (its
// address or key) is kept.

import { PREVIEW_APP } from "./attest.ts";
import { attestedCaller, rateLimited, type Options } from "./callers.ts";
import { bodyBytes, error, json, jsonObject } from "./http.ts";
import type { Env } from "./index.ts";
import { PERF_RETENTION_DAYS } from "./objects.ts";

/** Most histogram buckets a report may carry per histogram. */
export const MAX_BUCKETS = 24;
/** The longest bucket bound, in ms: ten minutes, far past any real launch. */
export const MAX_BUCKET_MS = 600_000;
/** The most launches one bucket may count. */
export const MAX_BUCKET_COUNT = 1_000_000;
/** The worst scroll hitch ratio a report may carry, in ms per second. */
export const MAX_HITCH_MS_PER_S = 1000;
/** The most one Sammy media count may be. */
export const MAX_MEDIA_COUNT = 1_000_000;
/** The days `GET /perf/reports` reads when it isn't told. */
export const DEFAULT_DAYS = 30;

/** One histogram bucket: `count` launches took from `startMs` to `endMs`. */
export interface Bucket {
  startMs: number;
  endMs: number;
  count: number;
}

/**
 * What one kind of Sammy media did since the last report (ADR 0039): grants
 * asked for, grant and byte requests the server answered with a 429,
 * requests the app held back after one, and (for pictures) grants it didn't
 * ask for because their allowance was spent. Since ADR 0040, also loads
 * straight from the source's public media servers (`direct`) and direct
 * loads that failed and went through a grant instead (`fallbacks`); a build
 * before it sends neither.
 */
export interface MediaCounts {
  grants: number;
  grantsRateLimited: number;
  bytesRateLimited: number;
  heldBack: number;
  deferred: number;
  direct?: number;
  fallbacks?: number;
}

/**
 * The upper bounds, in ms, of the time-to-image buckets (ADR 0040): from
 * asking for an image's bytes to having them, counted in the first bucket
 * whose bound it is within, and past the last bound in one more bucket.
 */
export const TIME_TO_IMAGE_BOUNDS_MS = [100, 250, 500, 1000, 2500, 5000] as const;
/** One count per bucket of `TIME_TO_IMAGE_BOUNDS_MS`, and one past the last. */
export const TIME_TO_IMAGE_BUCKETS = TIME_TO_IMAGE_BOUNDS_MS.length + 1;

/** How long Sammy images took to arrive, loaded directly and through a grant. */
export interface TimeToImage {
  direct: number[];
  grant: number[];
}

/** Sammy media counts for authors' pictures and for attachments. */
export interface SammyMedia {
  avatar: MediaCounts;
  attachment: MediaCounts;
  /** Since ADR 0040; a build before it sends none. */
  timeToImage?: TimeToImage;
}

/** A report as the app sends it. */
export interface PerfReport {
  /**
   * A random UUID the app made for this report alone, so one sent again
   * is stored once. It names no install.
   */
  id: string;
  platform: "ios" | "mac";
  /** CFBundleVersion. */
  build: string;
  /** The OS version, dotted numbers. */
  os: string;
  /** The hardware model, such as `iPhone16,2`. */
  device: string;
  periodStart: string;
  periodEnd: string;
  /** Scroll hitch time per second of scrolling; null when there was no scrolling to measure. */
  scrollHitchMsPerS: number | null;
  /** Time to first draw, as a histogram. */
  launch: Bucket[];
  /** Time to resume, as a histogram, when the payload had one. */
  resume?: Bucket[];
  /** What Sammy media grants did, when they did anything. */
  sammyMedia?: SammyMedia;
}

/**
 * A stored report: the report, when the Worker took it, and which app sent
 * it when that was Influx Preview (ADR 0042). The Worker adds the app from
 * the caller's attested key. A report can't name its own: `app` is not a
 * field a report may carry.
 */
export interface StoredReport extends PerfReport {
  receivedAt: string;
  app?: "preview";
}

const REPORT_FIELDS = new Set(["id", "platform", "build", "os", "device", "periodStart", "periodEnd", "scrollHitchMsPerS", "launch", "resume", "sammyMedia"]);
const MEDIA_KINDS = ["avatar", "attachment"] as const;
const MEDIA_COUNTS = ["grants", "grantsRateLimited", "bytesRateLimited", "heldBack", "deferred"] as const;
/** Counts a report may carry since ADR 0040, and an older build leaves out. */
const DIRECT_COUNTS = ["direct", "fallbacks"] as const;
const TIME_TO_IMAGE_PATHS = ["direct", "grant"] as const;
const UUID = /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/;
const BUCKET_FIELDS = new Set(["startMs", "endMs", "count"]);
const DOTTED = /^\d+(\.\d+)*$/;
const DEVICE = /^[A-Za-z0-9,]{1,24}$/;
const RFC3339 = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?(Z|[+-]\d{2}:\d{2})$/;

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Whether `value` has no field outside `allowed`. */
function onlyFields(value: Record<string, unknown>, allowed: Set<string>): boolean {
  return Object.keys(value).every((key) => allowed.has(key));
}

function isTime(value: unknown): value is string {
  return typeof value === "string" && value.length <= 40 && RFC3339.test(value) && !Number.isNaN(Date.parse(value));
}

function isInteger(value: unknown, min: number, max: number): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= min && value <= max;
}

function buckets(value: unknown): Bucket[] | undefined {
  if (!Array.isArray(value) || value.length > MAX_BUCKETS) return undefined;
  const result: Bucket[] = [];
  for (const bucket of value) {
    if (!isObject(bucket) || !onlyFields(bucket, BUCKET_FIELDS)) return undefined;
    const { startMs, endMs, count } = bucket;
    if (!isInteger(startMs, 0, MAX_BUCKET_MS - 1) || !isInteger(endMs, 1, MAX_BUCKET_MS) || startMs >= endMs) return undefined;
    if (!isInteger(count, 0, MAX_BUCKET_COUNT)) return undefined;
    result.push({ startMs, endMs, count });
  }
  return result;
}

/** `TIME_TO_IMAGE_BUCKETS` counts within the bound, for each way an image loads, and nothing else. */
function timeToImage(value: unknown): TimeToImage | undefined {
  if (!isObject(value) || Object.keys(value).length !== TIME_TO_IMAGE_PATHS.length || !onlyFields(value, new Set(TIME_TO_IMAGE_PATHS))) return undefined;
  const result = {} as TimeToImage;
  for (const path of TIME_TO_IMAGE_PATHS) {
    const counts = value[path];
    if (!Array.isArray(counts) || counts.length !== TIME_TO_IMAGE_BUCKETS || !counts.every((count) => isInteger(count, 0, MAX_MEDIA_COUNT))) return undefined;
    result[path] = [...counts];
  }
  return result;
}

/**
 * Both kinds' counts, each with exactly its fields (the direct counts, and
 * the time to image, only from a build that sends them), every one a count
 * within the bound.
 */
function sammyMedia(value: unknown): SammyMedia | undefined {
  if (!isObject(value) || !onlyFields(value, new Set([...MEDIA_KINDS, "timeToImage"]))) return undefined;
  if (!MEDIA_KINDS.every((kind) => kind in value)) return undefined;
  const result = {} as SammyMedia;
  for (const kind of MEDIA_KINDS) {
    const counts = value[kind];
    if (!isObject(counts) || !onlyFields(counts, new Set([...MEDIA_COUNTS, ...DIRECT_COUNTS]))) return undefined;
    // Both direct counts or neither: a build either knows of direct loads or does not.
    const direct = DIRECT_COUNTS.filter((name) => name in counts);
    if (direct.length !== 0 && direct.length !== DIRECT_COUNTS.length) return undefined;
    const taken = {} as MediaCounts;
    for (const name of [...MEDIA_COUNTS, ...direct]) {
      const count = counts[name];
      if (!isInteger(count, 0, MAX_MEDIA_COUNT)) return undefined;
      taken[name] = count;
    }
    result[kind] = taken;
  }
  if (value.timeToImage !== undefined) {
    const times = timeToImage(value.timeToImage);
    if (!times) return undefined;
    result.timeToImage = times;
  }
  return result;
}

/**
 * The report, with only its known fields, if every field is present (but
 * `resume` and `sammyMedia`), of its type and within its bounds, and there
 * is no other field; otherwise nothing.
 */
export function validReport(value: unknown): PerfReport | undefined {
  if (!isObject(value) || !onlyFields(value, REPORT_FIELDS)) return undefined;
  const { id, platform, build, os, device, periodStart, periodEnd, scrollHitchMsPerS } = value;
  if (typeof id !== "string" || !UUID.test(id)) return undefined;
  if (platform !== "ios" && platform !== "mac") return undefined;
  for (const version of [build, os]) {
    if (typeof version !== "string" || version.length > 20 || !DOTTED.test(version)) return undefined;
  }
  if (typeof device !== "string" || !DEVICE.test(device)) return undefined;
  if (!isTime(periodStart) || !isTime(periodEnd) || Date.parse(periodStart) > Date.parse(periodEnd)) return undefined;
  if (scrollHitchMsPerS !== null) {
    if (typeof scrollHitchMsPerS !== "number" || !Number.isFinite(scrollHitchMsPerS)) return undefined;
    if (scrollHitchMsPerS < 0 || scrollHitchMsPerS > MAX_HITCH_MS_PER_S) return undefined;
  }
  const launch = buckets(value.launch);
  if (!launch) return undefined;
  const report: PerfReport = {
    id,
    platform,
    build: build as string,
    os: os as string,
    device,
    periodStart,
    periodEnd,
    scrollHitchMsPerS,
    launch,
  };
  if (value.resume !== undefined) {
    const resume = buckets(value.resume);
    if (!resume) return undefined;
    report.resume = resume;
  }
  if (value.sammyMedia !== undefined) {
    const media = sammyMedia(value.sammyMedia);
    if (!media) return undefined;
    report.sammyMedia = media;
  }
  return report;
}

function perfReports(env: Env) {
  return env.PERF_REPORTS.get(env.PERF_REPORTS.idFromName("reports"));
}

/**
 * POST /perf/report: stores one report from an attested install. Body
 * `{"challenge", "report"}`, the challenge fresh from `/oauth/challenge`,
 * attested like an assertion request. Attestation is required whatever
 * REQUIRE_ATTESTATION says: a report nobody can vouch for is worth nothing.
 */
export async function report(request: Request, env: Env, options: Options): Promise<Response> {
  if (request.method !== "POST") return error(405, "method_not_allowed", { Allow: "POST" });
  if (await rateLimited(request, env)) return error(429, "rate_limited", { "Retry-After": "60" });
  // The exact bytes, because the assertion signs them.
  const raw = await bodyBytes(request);
  const body = raw && jsonObject(raw);
  if (!body || !onlyFields(body, new Set(["challenge", "report"]))) return error(400, "invalid_request");
  // Checked before attestation, so a malformed report spends no challenge.
  const report = validReport(body.report);
  if (!report) return error(400, "invalid_report");

  const { attested: attestation, appId } = await attestedCaller(request, raw, body, env, options);
  if (attestation === "unknown") return error(401, "key_unknown");
  if (attestation === "policy") {
    // `app_not_accepted` would also stop the app's Bluesky sign-ins for the
    // run, so it is given only once assertions get it too (ADR 0033).
    return env.REQUIRE_ATTESTATION === "true" ? error(403, "app_not_accepted") : error(403, "report_not_accepted");
  }
  if (attestation !== "attested") return error(401, "attestation_required");

  const kept = appId === PREVIEW_APP ? { ...report, app: "preview" } : report;
  const stored = await perfReports(env).fetch(new Request("https://perf/add", { method: "POST", body: JSON.stringify(kept) }));
  if (stored.status === 429) return error(503, "daily_limit", { "Retry-After": "3600" });
  if (stored.status !== 204) return error(503, "unavailable");
  return new Response(null, { status: 204, headers: { "Cache-Control": "no-store" } });
}

/**
 * GET /perf/reports?days=N: the last N days' reports (1 to 90, default
 * 30), newest first, and a summary per platform and build. Reports hold
 * nothing about who sent them, so reading them needs nothing, and counts
 * nothing.
 */
export async function reports(request: Request, env: Env): Promise<Response> {
  if (request.method !== "GET") return error(405, "method_not_allowed", { Allow: "GET" });
  if (await rateLimited(request, env)) return error(429, "rate_limited", { "Retry-After": "60" });
  const asked = new URL(request.url).searchParams.get("days");
  const days = asked === null ? DEFAULT_DAYS : /^\d{1,2}$/.test(asked) ? Number(asked) : 0;
  if (days < 1 || days > PERF_RETENTION_DAYS) return error(400, "invalid_days");
  const read = await perfReports(env).fetch(new Request(`https://perf/?days=${days}`));
  if (read.status !== 200) return error(503, "unavailable");
  const { reports } = (await read.json()) as { reports: StoredReport[] };
  return json(200, { days, reports, summaries: summarize(reports) }, { "Cache-Control": "no-store" });
}

// Summaries

export interface Percentiles {
  /** Reports whose histogram counted anything. */
  reports: number;
  /** How many it counts. */
  count: number;
  p50Ms: number | null;
  p90Ms: number | null;
}

export interface Hitches {
  /** Reports that measured scrolling. */
  reports: number;
  median: number | null;
  worst: number | null;
}

export interface Summary {
  /** Present for Influx Preview's builds, which are numbered apart from Influx's. */
  app?: "preview";
  platform: "ios" | "mac";
  build: string;
  reports: number;
  scrollHitchMsPerS: Hitches;
  /**
   * The same per hardware model, in model order: the bar is set on one
   * phone, and a faster or 60 Hz phone's figures don't show it is met.
   */
  scrollHitchByDevice: (Hitches & { device: string })[];
  launch: Percentiles;
  resume: Percentiles;
  /** Sammy media counts added up over the reports that carried them, which `reports` counts. */
  sammyMedia: MediaTotal;
}

/** Sammy media counts added up: every count, and the time to image, always present. */
export interface MediaTotal {
  reports: number;
  avatar: Required<MediaCounts>;
  attachment: Required<MediaCounts>;
  timeToImage: TimeToImage;
}


/** The median of `values`: the middle one, or the mean of the middle two. */
export function median(values: number[]): number | null {
  if (values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}

/** Histograms added together: buckets with the same bounds are summed, in order of their start. */
export function mergeBuckets(histograms: Bucket[][]): Bucket[] {
  const merged = new Map<string, Bucket>();
  for (const bucket of histograms.flat()) {
    const key = `${bucket.startMs}-${bucket.endMs}`;
    const found = merged.get(key);
    if (found) found.count += bucket.count;
    else merged.set(key, { ...bucket });
  }
  return [...merged.values()].sort((a, b) => a.startMs - b.startMs || a.endMs - b.endMs);
}

/**
 * The value below which `fraction` of the counts fall, estimated from a
 * histogram by taking each bucket's counts as spread evenly across it;
 * null when it counts nothing. Buckets may overlap, as different reports'
 * do once each has merged its own: their spreads add up, so the count
 * below a value rises in straight lines between the buckets' bounds, and
 * the answer is found on the line that reaches `fraction`.
 */
export function percentile(histogram: Bucket[], fraction: number): number | null {
  const buckets = histogram.filter((bucket) => bucket.count > 0);
  const total = buckets.reduce((sum, bucket) => sum + bucket.count, 0);
  if (total === 0) return null;
  const target = fraction * total;
  const below = (value: number) =>
    buckets.reduce((sum, bucket) => sum + bucket.count * Math.min(1, Math.max(0, (value - bucket.startMs) / (bucket.endMs - bucket.startMs))), 0);
  const bounds = [...new Set(buckets.flatMap((bucket) => [bucket.startMs, bucket.endMs]))].sort((a, b) => a - b);
  // Nothing is below the lowest bound.
  let previous = bounds[0];
  let previousBelow = 0;
  for (const bound of bounds.slice(1)) {
    const count = below(bound);
    if (count >= target) return previous + ((bound - previous) * (target - previousBelow)) / (count - previousBelow);
    previous = bound;
    previousBelow = count;
  }
  return bounds[bounds.length - 1];
}

function percentiles(histograms: Bucket[][]): Percentiles {
  const merged = mergeBuckets(histograms);
  return {
    reports: histograms.filter((histogram) => histogram.some((bucket) => bucket.count > 0)).length,
    count: merged.reduce((sum, bucket) => sum + bucket.count, 0),
    p50Ms: percentile(merged, 0.5),
    p90Ms: percentile(merged, 0.9),
  };
}

/** Newer first when a is newer than b; dotted numbers compare part by part. */
function newerBuild(a: string, b: string): number {
  const x = a.split(".").map(Number);
  const y = b.split(".").map(Number);
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    const difference = (y[i] ?? 0) - (x[i] ?? 0);
    if (difference !== 0) return difference;
  }
  return 0;
}

function noMedia(): Required<MediaCounts> {
  return { grants: 0, grantsRateLimited: 0, bytesRateLimited: 0, heldBack: 0, deferred: 0, direct: 0, fallbacks: 0 };
}

function noTimes(): TimeToImage {
  return { direct: Array<number>(TIME_TO_IMAGE_BUCKETS).fill(0), grant: Array<number>(TIME_TO_IMAGE_BUCKETS).fill(0) };
}

/** The Sammy media counts of the reports that carried them, added up; a
 * count or time a report's build didn't send adds nothing. */
function mediaOf(group: PerfReport[]): MediaTotal {
  const total: MediaTotal = { reports: 0, avatar: noMedia(), attachment: noMedia(), timeToImage: noTimes() };
  for (const report of group) {
    if (!report.sammyMedia) continue;
    total.reports += 1;
    for (const kind of MEDIA_KINDS) {
      for (const name of [...MEDIA_COUNTS, ...DIRECT_COUNTS]) total[kind][name] += report.sammyMedia[kind][name] ?? 0;
    }
    for (const path of TIME_TO_IMAGE_PATHS) {
      report.sammyMedia.timeToImage?.[path].forEach((count, bucket) => { total.timeToImage[path][bucket]! += count; });
    }
  }
  return total;
}

/** The median and worst of the reports that measured scrolling. */
function hitchesOf(group: PerfReport[]): Hitches {
  const hitches = group.map((report) => report.scrollHitchMsPerS).filter((value): value is number => value !== null);
  return {
    reports: hitches.length,
    // Unrounded, so a figure just under the bar isn't read as on it.
    median: median(hitches),
    worst: hitches.length === 0 ? null : Math.max(...hitches),
  };
}

/**
 * Per app, platform and build: how many reports, the median and worst scroll
 * hitch ratio among those that measured scrolling (also per hardware
 * model), launch and resume percentiles from every report's histograms
 * together, and the Sammy media counts added up. Influx first, then Influx
 * Preview; in each, iPhone first, then the Mac, newest build first.
 */
export function summarize(reports: (PerfReport & { app?: "preview" })[]): Summary[] {
  const groups = new Map<string, (PerfReport & { app?: "preview" })[]>();
  for (const report of reports) {
    const key = `${report.app ?? ""} ${report.platform} ${report.build}`;
    groups.set(key, [...(groups.get(key) ?? []), report]);
  }
  const summaries = [...groups.values()].map((group): Summary => {
    const devices = [...new Set(group.map((report) => report.device))].sort();
    return {
      ...(group[0].app ? { app: group[0].app } : {}),
      platform: group[0].platform,
      build: group[0].build,
      reports: group.length,
      scrollHitchMsPerS: hitchesOf(group),
      scrollHitchByDevice: devices.map((device) => ({ device, ...hitchesOf(group.filter((report) => report.device === device)) })),
      launch: percentiles(group.map((report) => report.launch)),
      resume: percentiles(group.map((report) => report.resume ?? [])),
      sammyMedia: mediaOf(group),
    };
  });
  return summaries.sort((a, b) => {
    if (a.app !== b.app) return a.app ? 1 : -1;
    return a.platform === b.platform ? newerBuild(a.build, b.build) : a.platform === "ios" ? -1 : 1;
  });
}
