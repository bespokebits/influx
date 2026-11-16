#!/usr/bin/env node
// Starts and follows Influx's TestFlight builds: the Xcode Cloud workflow
// "TestFlight (manual)", which archives iOS and macOS and hands both to the
// internal testers. Builds reach the test devices only this way (AGENTS.md).
//
//   scripts/testflight.mjs start [branch] [--dry-run] [--anyway]   default branch: main
//   scripts/testflight.mjs status                       the last runs and builds
//   scripts/testflight.mjs lane                         every Xcode Cloud product's runs in progress
//   scripts/testflight.mjs wait <run number>            until the run ends
//   scripts/testflight.mjs external                     what external (public) testing has and lacks
//   scripts/testflight.mjs prepare                      set the test information, review details and public group
//   scripts/testflight.mjs submit <build> <file>        send a build to the public group and Beta App Review
//   scripts/testflight.mjs public-link <limit>          open the public group's link to at most <limit> testers
//
// The account's Xcode Cloud products share one build lane, so `start` refuses
// (exit 3) while a run of any product is in progress, this one's included,
// and says which. `--anyway` starts regardless.
//
// `wait` exits 0 when the run succeeded and its builds are ready for internal
// testing, 1 when it failed, and 2 on a usage or setup error.
//
// Credentials: an App Store Connect API key, from the file named by
// INFLUX_ASC_ENV (default ~/.config/influx/asc.env, mode 600, never
// committed), with ASC_KEY_ID, ASC_ISSUER_ID and ASC_P8_BASE64 (the .p8,
// base64). The key needs the App Manager role: `start` and `wait` would do
// with less, but App Store Connect refuses `prepare`, `submit` and
// `public-link` to any role below App Manager. Nothing here prints the key.
//
// Public testing also needs the workflow's archives to be made for the App
// Store: Distribution Preparation "App Store Connect", not "TestFlight
// (Internal Testing Only)". A build archived for internal testing only can
// never join an external group. `external` shows the setting; it can be
// changed only in the workflow editor, as the API refuses it.
//
// `prepare` also reads the Beta App Review contact, which Apple keeps private,
// from INFLUX_REVIEW_CONTACT (default ~/.config/influx/review-contact.env,
// never committed): CONTACT_FIRST_NAME, CONTACT_LAST_NAME and CONTACT_PHONE.
// Nothing here prints them.
import { createSign } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const BUNDLE_ID = "dev.bespokebits.influx";
const WORKFLOW = "TestFlight (manual)";
const API = "https://api.appstoreconnect.apple.com";
const POLL_SECONDS = 60;
/** Build states that end a wait as a failure: they don't clear by themselves. */
const FAILED_PROCESSING = new Set(["INVALID", "FAILED"]);
const FAILED_TESTING = new Set(["PROCESSING_EXCEPTION", "MISSING_EXPORT_COMPLIANCE", "EXPIRED"]);

// External (public) testing. These are shown on the TestFlight page.
const LOCALE = "en-US";
const PUBLIC_GROUP = "Public Beta";
const FEEDBACK_EMAIL = "influx-feedback@bespokebits.dev";
const PRIVACY_URL = "https://influx.bespokebits.dev/privacy";
const DESCRIPTION =
  "Influx reads your RSS feeds and your Bluesky and Mastodon timelines together, oldest first, " +
  "so you catch up from where you left off. Your sources and your place sync through iCloud, " +
  "and the timeline is built to scroll smoothly through thousands of posts.";
// For Beta App Review only.
const REVIEW_NOTES =
  "No sign-in is needed. On iPhone, open Sources and choose Add Feed…; on the Mac, choose File > Add Feed…. " +
  "Any RSS feed address works, " +
  "for example https://www.apple.com/newsroom/rss-feed.rss. Bluesky and Mastodon timelines need an " +
  "account of the reviewer's own on those services; Influx has no account of its own.";
/** External states in which a build is already with Beta App Review or past it. */
const SUBMITTED = new Set(["WAITING_FOR_BETA_REVIEW", "IN_BETA_REVIEW", "BETA_APPROVED", "IN_BETA_TESTING"]);

function fail(message, code = 2) {
  console.error(`testflight: ${message}`);
  process.exit(code);
}

let credentials;
function loadCredentials() {
  const file = process.env.INFLUX_ASC_ENV ?? join(homedir(), ".config/influx/asc.env");
  if (!existsSync(file)) fail(`no credentials file at ${file} (see the header of this script)`);
  process.loadEnvFile(file);
  const { ASC_KEY_ID: kid, ASC_ISSUER_ID: iss, ASC_P8_BASE64: p8 } = process.env;
  if (!kid || !iss || !p8) fail(`${file} needs ASC_KEY_ID, ASC_ISSUER_ID and ASC_P8_BASE64`);
  return { kid, iss, key: Buffer.from(p8, "base64").toString("utf8") };
}

// Apple allows a token at most 20 minutes, and a run takes longer, so `wait`
// makes a new one a minute before the last one expires.
const TOKEN_SECONDS = 1200;
let jwt;
let jwtExpires = 0;
function token() {
  credentials ??= loadCredentials();
  const { kid, iss, key } = credentials;
  const part = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
  const now = Math.floor(Date.now() / 1000);
  const unsigned = `${part({ alg: "ES256", kid, typ: "JWT" })}.${part({ iss, iat: now, exp: now + TOKEN_SECONDS, aud: "appstoreconnect-v1" })}`;
  const signature = createSign("SHA256").update(unsigned).sign({ key, dsaEncoding: "ieee-p1363" }).toString("base64url");
  jwtExpires = now + TOKEN_SECONDS;
  return `${unsigned}.${signature}`;
}

async function api(path, init = {}) {
  if (!jwt || Date.now() / 1000 > jwtExpires - 60) jwt = token();
  const response = await fetch(`${API}${path}`, {
    ...init,
    headers: { Authorization: `Bearer ${jwt}`, "Content-Type": "application/json", ...init.headers },
  });
  if (!response.ok) {
    const detail = (await response.text()).slice(0, 400);
    fail(`${init.method ?? "GET"} ${path} answered ${response.status}: ${detail}`);
  }
  return response.status === 204 ? null : response.json();
}

async function product() {
  const apps = await api(`/v1/apps?filter[bundleId]=${BUNDLE_ID}`);
  const app = apps.data.find((a) => a.attributes.bundleId === BUNDLE_ID);
  if (!app) fail(`no App Store Connect app for ${BUNDLE_ID}`);
  return { app, product: (await api(`/v1/apps/${app.id}/ciProduct`)).data };
}

async function workflow(productID) {
  const workflows = await api(`/v1/ciProducts/${productID}/workflows`);
  const found = workflows.data.find((w) => w.attributes.name === WORKFLOW);
  if (!found) fail(`no Xcode Cloud workflow named "${WORKFLOW}"`);
  if (!found.attributes.isEnabled) fail(`the "${WORKFLOW}" workflow is disabled`);
  return found;
}

async function branchRef(workflowID, branch) {
  const repository = (await api(`/v1/ciWorkflows/${workflowID}/repository`)).data;
  let next = `/v1/scmRepositories/${repository.id}/gitReferences?limit=200`;
  while (next) {
    const page = await api(next);
    const ref = page.data.find((r) => r.attributes.kind === "BRANCH" && r.attributes.name === branch && !r.attributes.isDeleted);
    if (ref) return ref;
    next = page.links?.next?.replace(API, "");
  }
  fail(`Xcode Cloud doesn't know a branch "${branch}" (push it first)`);
}

/** The runs in progress, per Xcode Cloud product of the account. */
async function busy() {
  const out = [];
  for (const p of (await api("/v1/ciProducts?limit=200")).data) {
    const active = (await runs(p.id, 5)).filter((r) => r.attributes.executionProgress !== "COMPLETE");
    out.push({ name: p.attributes.name, active: active.map((r) => `run ${r.attributes.number} ${r.attributes.executionProgress}`) });
  }
  return out;
}

async function lane() {
  for (const p of await busy()) console.log(`${p.name}: ${p.active.length ? p.active.join(", ") : "idle"}`);
}

async function start(branch, dryRun, anyway) {
  if (!anyway) {
    const running = (await busy()).filter((p) => p.active.length);
    if (running.length) {
      for (const p of running) console.error(`testflight: ${p.name} is building: ${p.active.join(", ")}`);
      fail("the Xcode Cloud lane is busy; try again when it is idle, or pass --anyway", 3);
    }
  }
  const { product: ciProduct } = await product();
  const flow = await workflow(ciProduct.id);
  const ref = await branchRef(flow.id, branch);
  if (dryRun) {
    console.log(`would start "${WORKFLOW}" on ${ref.attributes.canonicalName}`);
    return;
  }
  const run = await api("/v1/ciBuildRuns", {
    method: "POST",
    body: JSON.stringify({
      data: {
        type: "ciBuildRuns",
        relationships: {
          workflow: { data: { type: "ciWorkflows", id: flow.id } },
          sourceBranchOrTag: { data: { type: "scmGitReferences", id: ref.id } },
        },
      },
    }),
  });
  console.log(`started run ${run.data.attributes.number} of "${WORKFLOW}" on ${branch}`);
  console.log(`follow it with: scripts/testflight.mjs wait ${run.data.attributes.number}`);
}

async function runs(productID, limit) {
  return (await api(`/v1/ciProducts/${productID}/buildRuns?limit=${limit}&sort=-number`)).data;
}

async function describe(run) {
  const a = run.attributes;
  const lines = [`run ${a.number}: ${a.executionProgress} ${a.completionStatus ?? ""} commit ${a.sourceCommit?.commitSha?.slice(0, 7) ?? "?"}`.trimEnd()];
  for (const action of (await api(`/v1/ciBuildRuns/${run.id}/actions`)).data) {
    const s = action.attributes;
    const issues = s.issueCounts ?? {};
    lines.push(`  ${s.name}: ${s.executionProgress} ${s.completionStatus ?? ""} errors=${issues.errors ?? 0} testFailures=${issues.testFailures ?? 0}`);
  }
  return lines;
}

/** The TestFlight builds from `run`, with their internal testing state. */
async function buildsOf(run) {
  // The run's own list names its builds but leaves their details empty, so
  // they are read again by ID.
  const ids = (await api(`/v1/ciBuildRuns/${run.id}/builds`)).data.map((b) => b.id);
  if (ids.length === 0) return [];
  const builds = await api(`/v1/builds?filter[id]=${ids.join(",")}&include=preReleaseVersion,buildBetaDetail`);
  const included = Object.fromEntries((builds.included ?? []).map((i) => [`${i.type}:${i.id}`, i.attributes]));
  return builds.data.map((b) => {
    const version = included[`preReleaseVersions:${b.relationships.preReleaseVersion?.data?.id}`] ?? {};
    const beta = included[`buildBetaDetails:${b.relationships.buildBetaDetail?.data?.id}`] ?? {};
    return { platform: version.platform ?? "?", version: version.version ?? "?", build: b.attributes.version, processing: b.attributes.processingState, testing: beta.internalBuildState ?? "?" };
  });
}

/** What external testing needs, read only: test information, the Beta App
 *  Review contact, the beta licence, the groups and public links, and the
 *  newest builds' external state. Prints values that are public on the
 *  TestFlight page, and only whether the review contact is filled in. */
async function external() {
  const { app, product: ci } = await product();
  const set = (value) => (value ? "set" : "MISSING");
  console.log(`app: ${app.attributes.name} (${app.attributes.bundleId}), primary locale ${app.attributes.primaryLocale}`);
  const localizations = (await api(`/v1/apps/${app.id}/betaAppLocalizations`)).data;
  if (localizations.length === 0) console.log("test information: MISSING (no beta app localization)");
  for (const l of localizations) {
    const a = l.attributes;
    console.log(`test information (${a.locale}): description ${set(a.description)}, feedback email ${set(a.feedbackEmail)}, ` +
      `privacy policy ${a.privacyPolicyUrl ?? "MISSING"}, marketing ${a.marketingUrl ?? "none"}`);
  }
  const review = (await api(`/v1/apps/${app.id}/betaAppReviewDetail`)).data?.attributes ?? {};
  console.log(`beta review contact: name ${set(review.contactFirstName && review.contactLastName)}, email ${set(review.contactEmail)}, ` +
    `phone ${set(review.contactPhone)}; sign-in required ${review.demoAccountRequired ? "yes" : "no"}; notes ${set(review.notes)}`);
  const licence = (await api(`/v1/apps/${app.id}/betaLicenseAgreement`)).data?.attributes ?? {};
  console.log(`beta licence agreement: ${licence.agreementText ? "custom" : "Apple's standard"}`);
  const groups = (await api(`/v1/apps/${app.id}/betaGroups`)).data;
  for (const g of groups) {
    const a = g.attributes;
    console.log(`group "${a.name}": ${a.isInternalGroup ? "internal" : "external"}` +
      (a.isInternalGroup ? "" : `, public link ${a.publicLinkEnabled ? `on (${a.publicLink}, limit ${a.publicLinkLimit ?? "none"})` : "off"}`));
  }
  if (!groups.some((g) => !g.attributes.isInternalGroup)) console.log("external group: MISSING");
  for (const a of (await api(`/v1/ciWorkflows/${(await workflow(ci.id)).id}`)).data.attributes.actions ?? []) {
    if (a.actionType !== "ARCHIVE") continue;
    const audience = { APP_STORE_ELIGIBLE: "App Store Connect", INTERNAL_ONLY: "internal testing only: its builds can't go external" };
    console.log(`workflow "${WORKFLOW}", ${a.name}: ${audience[a.buildDistributionAudience] ?? a.buildDistributionAudience ?? "?"}`);
  }
  const builds = await api(`/v1/builds?filter[app]=${app.id}&sort=-uploadedDate&limit=4&include=buildBetaDetail,preReleaseVersion`);
  const included = Object.fromEntries((builds.included ?? []).map((i) => [`${i.type}:${i.id}`, i.attributes]));
  for (const b of builds.data) {
    const version = included[`preReleaseVersions:${b.relationships.preReleaseVersion?.data?.id}`] ?? {};
    const beta = included[`buildBetaDetails:${b.relationships.buildBetaDetail?.data?.id}`] ?? {};
    console.log(`build ${version.platform ?? "?"} ${version.version ?? "?"} (${b.attributes.version}): ${b.attributes.processingState}, ` +
      `encryption declared ${b.attributes.usesNonExemptEncryption === false ? "none" : b.attributes.usesNonExemptEncryption ?? "?"}, ` +
      `internal ${beta.internalBuildState ?? "?"}, external ${beta.externalBuildState ?? "?"}`);
  }
}

/** The external group that the public link belongs to, or undefined. */
async function publicGroup(appID) {
  return (await api(`/v1/apps/${appID}/betaGroups?limit=200`)).data
    .find((g) => !g.attributes.isInternalGroup && g.attributes.name === PUBLIC_GROUP);
}

/** The private review contact, or undefined when its file is missing. */
function reviewContact() {
  const file = process.env.INFLUX_REVIEW_CONTACT ?? join(homedir(), ".config/influx/review-contact.env");
  if (!existsSync(file)) return undefined;
  process.loadEnvFile(file);
  const { CONTACT_FIRST_NAME: first, CONTACT_LAST_NAME: last, CONTACT_PHONE: phone } = process.env;
  if (!first || !last || !phone) fail(`${file} needs CONTACT_FIRST_NAME, CONTACT_LAST_NAME and CONTACT_PHONE`);
  return { contactFirstName: first, contactLastName: last, contactPhone: phone };
}

/** Sets what external testing needs and makes the public group, with its
 *  link closed. Safe to run again: it updates what is there. */
async function prepare() {
  const { app } = await product();
  const info = { description: DESCRIPTION, feedbackEmail: FEEDBACK_EMAIL, privacyPolicyUrl: PRIVACY_URL };
  const existing = (await api(`/v1/apps/${app.id}/betaAppLocalizations`)).data.find((l) => l.attributes.locale === LOCALE);
  if (existing) {
    await api(`/v1/betaAppLocalizations/${existing.id}`, {
      method: "PATCH",
      body: JSON.stringify({ data: { type: "betaAppLocalizations", id: existing.id, attributes: info } }),
    });
  } else {
    await api("/v1/betaAppLocalizations", {
      method: "POST",
      body: JSON.stringify({
        data: {
          type: "betaAppLocalizations",
          attributes: { locale: LOCALE, ...info },
          relationships: { app: { data: { type: "apps", id: app.id } } },
        },
      }),
    });
  }
  console.log(`test information (${LOCALE}): set`);
  const contact = reviewContact();
  const detail = (await api(`/v1/apps/${app.id}/betaAppReviewDetail`)).data;
  await api(`/v1/betaAppReviewDetails/${detail.id}`, {
    method: "PATCH",
    body: JSON.stringify({
      data: {
        type: "betaAppReviewDetails",
        id: detail.id,
        attributes: { contactEmail: FEEDBACK_EMAIL, demoAccountRequired: false, notes: REVIEW_NOTES, ...contact },
      },
    }),
  });
  console.log(`beta review details: set${contact ? "" : "; contact name and phone MISSING (no review contact file)"}`);
  if (await publicGroup(app.id)) {
    console.log(`group "${PUBLIC_GROUP}": already there`);
  } else {
    await api("/v1/betaGroups", {
      method: "POST",
      body: JSON.stringify({
        data: {
          type: "betaGroups",
          attributes: { name: PUBLIC_GROUP, publicLinkEnabled: false, feedbackEnabled: true },
          relationships: { app: { data: { type: "apps", id: app.id } } },
        },
      }),
    });
    console.log(`group "${PUBLIC_GROUP}": made, link closed`);
  }
  if (!contact) process.exit(1);
}

/** Gives every platform's build `number` the "What to Test" text in `file`,
 *  adds it to the public group and submits it for Beta App Review. Builds
 *  already submitted or approved are left as they are. */
async function submit(number, file) {
  if (!existsSync(file)) fail(`no file ${file}`);
  const whatsNew = readFileSync(file, "utf8").trim();
  if (!whatsNew || whatsNew.length > 4000) fail(`${file} must hold 1 to 4,000 characters of "What to Test"`);
  const { app } = await product();
  const group = await publicGroup(app.id);
  if (!group) fail(`no group "${PUBLIC_GROUP}": run prepare first`);
  const builds = await api(`/v1/builds?filter[app]=${app.id}&filter[version]=${number}&include=buildBetaDetail,preReleaseVersion&limit=10`);
  if (builds.data.length === 0) fail(`no build ${number}`);
  const included = Object.fromEntries((builds.included ?? []).map((i) => [`${i.type}:${i.id}`, i.attributes]));
  const platformOf = (b) => included[`preReleaseVersions:${b.relationships.preReleaseVersion?.data?.id}`]?.platform ?? "?";
  const stateOf = (b) => included[`buildBetaDetails:${b.relationships.buildBetaDetail?.data?.id}`]?.externalBuildState;
  // Every build is checked before anything changes, so a refusal leaves
  // none of them half sent.
  for (const b of builds.data) {
    if (b.attributes.processingState !== "VALID") fail(`${platformOf(b)} build ${number} is ${b.attributes.processingState}, not VALID`);
    if (stateOf(b) === "NOT_APPLICABLE") {
      fail(`${platformOf(b)} build ${number} was archived for internal testing only and can never go external; ` +
        `set the workflow's archives to "App Store Connect" (see the header) and make a new build`);
    }
  }
  for (const b of builds.data) {
    const platform = platformOf(b);
    const state = stateOf(b);
    const localizations = (await api(`/v1/builds/${b.id}/betaBuildLocalizations`)).data;
    const localization = localizations.find((l) => l.attributes.locale === LOCALE);
    if (localization) {
      await api(`/v1/betaBuildLocalizations/${localization.id}`, {
        method: "PATCH",
        body: JSON.stringify({ data: { type: "betaBuildLocalizations", id: localization.id, attributes: { whatsNew } } }),
      });
    } else {
      await api("/v1/betaBuildLocalizations", {
        method: "POST",
        body: JSON.stringify({
          data: {
            type: "betaBuildLocalizations",
            attributes: { locale: LOCALE, whatsNew },
            relationships: { build: { data: { type: "builds", id: b.id } } },
          },
        }),
      });
    }
    await api(`/v1/betaGroups/${group.id}/relationships/builds`, {
      method: "POST",
      body: JSON.stringify({ data: [{ type: "builds", id: b.id }] }),
    });
    if (SUBMITTED.has(state)) {
      console.log(`${platform} build ${number}: in the group; already ${state}`);
      continue;
    }
    await api("/v1/betaAppReviewSubmissions", {
      method: "POST",
      body: JSON.stringify({
        data: { type: "betaAppReviewSubmissions", relationships: { build: { data: { type: "builds", id: b.id } } } },
      }),
    });
    console.log(`${platform} build ${number}: in the group, submitted for Beta App Review`);
  }
}

/** Opens the public group's link, capped at `limit` testers. */
async function publicLink(limit) {
  const { app } = await product();
  const group = await publicGroup(app.id);
  if (!group) fail(`no group "${PUBLIC_GROUP}": run prepare first`);
  const updated = await api(`/v1/betaGroups/${group.id}`, {
    method: "PATCH",
    body: JSON.stringify({
      data: {
        type: "betaGroups",
        id: group.id,
        attributes: { publicLinkEnabled: true, publicLinkLimitEnabled: true, publicLinkLimit: limit },
      },
    }),
  });
  const a = updated.data.attributes;
  console.log(`group "${PUBLIC_GROUP}": public link ${a.publicLinkEnabled ? "on" : "off"}, ${a.publicLink ?? "no link yet"}, limit ${a.publicLinkLimit}`);
}

async function status() {
  const { product: ciProduct } = await product();
  for (const run of await runs(ciProduct.id, 3)) {
    console.log((await describe(run)).join("\n"));
    for (const b of await buildsOf(run)) console.log(`  TestFlight ${b.platform} ${b.version} (${b.build}): ${b.processing}, internal ${b.testing}`);
  }
}

/** The run with `number`, looked up once across every page of runs. */
async function runID(productID, number) {
  let next = `/v1/ciProducts/${productID}/buildRuns?limit=200&sort=-number`;
  while (next) {
    const page = await api(next);
    const found = page.data.find((r) => r.attributes.number === number);
    if (found) return found.id;
    next = page.links?.next?.replace(API, "");
  }
  fail(`no run ${number}`);
}

async function wait(number) {
  const { product: ciProduct } = await product();
  // Polled by ID, so newer runs can't push it out of sight.
  const id = await runID(ciProduct.id, number);
  for (;;) {
    const run = (await api(`/v1/ciBuildRuns/${id}`)).data;
    const a = run.attributes;
    if (a.executionProgress === "COMPLETE") {
      console.log((await describe(run)).join("\n"));
      if (a.completionStatus !== "SUCCEEDED") process.exit(1);
      // The builds then process in App Store Connect before testers get them.
      for (;;) {
        const builds = await buildsOf(run);
        const ready = builds.length > 0 && builds.every((b) => b.processing === "VALID" && b.testing === "IN_BETA_TESTING");
        const failed = builds.some((b) => FAILED_PROCESSING.has(b.processing) || FAILED_TESTING.has(b.testing));
        if (ready || failed) {
          for (const b of builds) console.log(`TestFlight ${b.platform} ${b.version} (${b.build}): ${b.processing}, internal ${b.testing}`);
          process.exit(ready ? 0 : 1);
        }
        await new Promise((r) => setTimeout(r, POLL_SECONDS * 1000));
      }
    }
    await new Promise((r) => setTimeout(r, POLL_SECONDS * 1000));
  }
}

const USAGE = "usage: scripts/testflight.mjs start [branch] [--dry-run] [--anyway] | status | lane | external | prepare | submit <build> <what-to-test file> | public-link <limit> | wait <run number>";
const [command, ...rest] = process.argv.slice(2);
const flags = rest.filter((r) => r.startsWith("-"));
const args = rest.filter((r) => !r.startsWith("-"));
// Anything unexpected is refused before any request: a mistyped --dry-run
// must not start a real build.
const allowedFlags = command === "start" ? ["--dry-run", "--anyway"] : [];
const maxArgs = { start: 1, status: 0, lane: 0, external: 0, prepare: 0, submit: 2, "public-link": 1, wait: 1 }[command];
const minArgs = { submit: 2, "public-link": 1, wait: 1 }[command] ?? 0;
if (maxArgs === undefined || args.length > maxArgs || args.length < minArgs || flags.some((f) => !allowedFlags.includes(f))) fail(USAGE);
switch (command) {
  case "start":
    await start(args[0] ?? "main", flags.includes("--dry-run"), flags.includes("--anyway"));
    break;
  case "lane":
    await lane();
    break;
  case "external":
    await external();
    break;
  case "status":
    await status();
    break;
  case "prepare":
    await prepare();
    break;
  case "submit":
    if (!/^\d+$/.test(args[0])) fail(USAGE);
    await submit(args[0], args[1]);
    break;
  case "public-link": {
    // TestFlight allows 1 to 10,000 testers per link.
    const limit = /^\d+$/.test(args[0]) ? Number(args[0]) : NaN;
    if (!(limit >= 1 && limit <= 10000)) fail(USAGE);
    await publicLink(limit);
    break;
  }
  case "wait": {
    const number = /^\d+$/.test(args[0] ?? "") ? Number(args[0]) : NaN;
    if (!Number.isInteger(number)) fail(USAGE);
    await wait(number);
    break;
  }
}
