#!/usr/bin/env node
// Checks each Influx build against the performance bar from the field
// reports TestFlight installs send (ADR 0034; AGENTS.md "Performance rules"):
// under 5 ms/s of scroll hitches and under 300 ms to the cached feed.
//
//   scripts/perf-report.mjs [days] [--json]   days: 1 to 90, default 30
//
// It reads GET /perf/reports from the OAuth Worker and prints, per platform
// and build, the reports, the hitch median and worst, and launch p50 and p90.
// A figure is judged only with evidence: hitches (the median report's) from
// at least 3 reports that measured scrolling on the iPhone 15 Pro Max
// (iPhone16,2), the phone the bar is set on (the Mac sends none; other
// phones are shown, not judged); launch from at least 3 reports that
// counted launches. MetricKit's launch
// time ends at the first frame, before the cached rows are drawn, so it is
// only a lower bound: a first-draw p50 at 300 ms or over misses the bar, but
// one under it doesn't show the cached feed meets it (the simulator launch
// test does, at milestones). So a build meets the field bar on its hitches
// alone, and a build without that evidence (every Mac build) is
// inconclusive. Each build also shows what Sammy media grants did (ADR
// 0039): grants asked for, 429s and requests held back, for authors'
// pictures and attachments apart, and since ADR 0040 the loads that went
// straight to the source, the ones that fell back to a grant, and how long
// images took to arrive each way; they inform, and never change a verdict.
// Exits 1 when a build misses the bar, 0 otherwise, and 2 on
// a usage or network error. `--json` prints the Worker's answer as it came.
// INFLUX_PERF_URL points it at another Worker. It needs no credentials.

const URL_DEFAULT = "https://influx.bespokebits.dev/perf/reports";
const HITCH_BAR_MS_PER_S = 5;
const LAUNCH_BAR_MS = 300;
const MIN_REPORTS = 3;
/** iPhone 15 Pro Max, the slowest supported 120 Hz phone, which the hitch bar is set on. */
const TARGET_PHONE = "iPhone16,2";

function fail(message) {
  console.error(`perf-report: ${message}`);
  process.exit(2);
}

const args = process.argv.slice(2);
const asJson = args.includes("--json");
const rest = args.filter((arg) => arg !== "--json");
if (rest.length > 1 || (rest[0] !== undefined && !/^\d{1,2}$/.test(rest[0]))) fail("usage: perf-report.mjs [days] [--json]");
const days = rest[0] === undefined ? 30 : Number(rest[0]);
if (days < 1 || days > 90) fail("days must be 1 to 90");

const url = new URL(process.env.INFLUX_PERF_URL ?? URL_DEFAULT);
url.searchParams.set("days", String(days));
let answer;
try {
  const response = await fetch(url, { headers: { Accept: "application/json" } });
  if (!response.ok) fail(`${url.origin} answered HTTP ${response.status}`);
  answer = await response.json();
} catch (error) {
  fail(`couldn't read ${url.origin}: ${error.message}`);
}
if (asJson) {
  console.log(JSON.stringify(answer, null, 2));
}

/** A figure for display, to at most four decimals; the verdict uses it unrounded. */
const show = (value, unit) => (value === null ? "-" : `${Number(value.toFixed(4))} ${unit}`);

/**
 * A build's verdict: "misses" when a figure with enough evidence is over
 * the bar, "meets" when its hitches are measured and under it, and
 * otherwise "inconclusive", with what is missing.
 */
function judge(summary) {
  const misses = [];
  const unjudged = [];
  // Only the iPhone measures scroll hitches (ADR 0034), and the bar is set
  // on one model: another phone's figures don't show it is met.
  if (summary.platform === "ios") {
    const hitch = (summary.scrollHitchByDevice ?? []).find((entry) => entry.device === TARGET_PHONE) ?? { reports: 0, median: null };
    if (hitch.reports < MIN_REPORTS || hitch.median === null) unjudged.push(`hitches measured on ${TARGET_PHONE} in ${hitch.reports} reports (needs ${MIN_REPORTS})`);
    else if (hitch.median >= HITCH_BAR_MS_PER_S) misses.push(`hitches ${show(hitch.median, "ms/s")} on ${TARGET_PHONE} (bar < ${HITCH_BAR_MS_PER_S})`);
  } else {
    unjudged.push("the Mac measures no scroll hitches, and first draw only bounds the cached feed from below");
  }
  // First draw comes before the cached rows, so it can only show a miss.
  const launch = summary.launch;
  if (launch.reports >= MIN_REPORTS && launch.p50Ms !== null && launch.p50Ms >= LAUNCH_BAR_MS) {
    misses.push(`first draw p50 ${show(launch.p50Ms, "ms")}, so the cached feed is over ${LAUNCH_BAR_MS} ms`);
  }
  if (misses.length > 0) return { verdict: "misses", reasons: misses };
  return unjudged.length > 0 ? { verdict: "inconclusive", reasons: unjudged } : { verdict: "meets", reasons: [] };
}

/** The time-to-image buckets' upper bounds, in ms (the Worker's TIME_TO_IMAGE_BOUNDS_MS). */
const TIME_TO_IMAGE_BOUNDS_MS = [100, 250, 500, 1000, 2500, 5000];

/** One way's time to image, as counts per bucket, when it counted any. */
function timeLine(name, counts) {
  if (!Array.isArray(counts) || counts.every((count) => count === 0)) return [];
  const labels = [...TIME_TO_IMAGE_BOUNDS_MS.map((bound) => `≤${bound}ms`), `>${TIME_TO_IMAGE_BOUNDS_MS.at(-1)}ms`];
  return [`    ${name} time to image: ${counts.map((count, index) => `${labels[index]} ${count}`).join(", ")}`];
}

/** What Sammy media grants and direct loads did, per kind, when any report counted them. */
function mediaLines(media) {
  if (!media || media.reports === 0) return [];
  const kind = (name, counts) =>
    `    ${name}: ${counts.direct ?? 0} direct, ${counts.fallbacks ?? 0} fell back, ${counts.grants} grants, ` +
    `${counts.grantsRateLimited} grant 429s, ${counts.bytesRateLimited} byte 429s, ` +
    `${counts.heldBack} held back` + (name === "pictures" ? `, ${counts.deferred} waited for their allowance` : "");
  return [
    `  sammy media (${media.reports} report${media.reports === 1 ? "" : "s"}):`,
    kind("pictures", media.avatar),
    kind("attachments", media.attachment),
    ...timeLine("direct", media.timeToImage?.direct),
    ...timeLine("grant", media.timeToImage?.grant),
  ];
}

const summaries = answer.summaries ?? [];
let missed = false;
if (!asJson) {
  console.log(`Field reports, last ${answer.days} days: ${answer.reports?.length ?? 0} in all.`);
  if (summaries.length === 0) console.log("No reports yet.");
}
for (const summary of summaries) {
  const { verdict, reasons } = judge(summary);
  if (verdict === "misses") missed = true;
  if (asJson) continue;
  const hitch = summary.scrollHitchMsPerS;
  console.log(
    [
      `${summary.platform} build ${summary.build}: ${summary.reports} report${summary.reports === 1 ? "" : "s"}`,
      `  hitches: median ${show(hitch.median, "ms/s")}, worst ${show(hitch.worst, "ms/s")} (${hitch.reports} measured)`,
      ...(summary.scrollHitchByDevice ?? [])
        .filter((entry) => entry.reports > 0)
        .map((entry) => `    ${entry.device}: median ${show(entry.median, "ms/s")}, worst ${show(entry.worst, "ms/s")} (${entry.reports} measured)`),
      `  first draw: p50 ${show(summary.launch.p50Ms, "ms")}, p90 ${show(summary.launch.p90Ms, "ms")} (${summary.launch.count} launches in ${summary.launch.reports} reports)`,
      `  resume: p50 ${show(summary.resume.p50Ms, "ms")}, p90 ${show(summary.resume.p90Ms, "ms")} (${summary.resume.count} resumes in ${summary.resume.reports} reports)`,
      ...mediaLines(summary.sammyMedia),
      `  ${verdict === "meets" ? "meets the field bar (hitches; the cached-feed time is the simulator launch test's)" : verdict === "misses" ? `MISSES the bar: ${reasons.join("; ")}` : `inconclusive: ${reasons.join("; ")}`}`,
    ].join("\n"),
  );
}
process.exit(missed ? 1 : 0);
