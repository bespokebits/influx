// Caller attestation (ADR 0033): an install proves with App Attest that it
// is a genuine Influx, iPhone or Mac, before the signing service signs for
// it. It asks for a challenge, registers its key with an attestation over
// that challenge, then for each assertion request asks for another and
// signs the request, which names it, with the key.

import { APPLE_ROOTS, ATTESTED_APPS, verifyAssertion, verifyAttestation, type Roots, type VerifiedAttestation } from "./attest.ts";
import { base64url, fromBase64, refuse, Refusal, toBase64 } from "./bytes.ts";
import { bodyBytes, error, json, jsonObject } from "./http.ts";
import type { Env } from "./index.ts";
import { appAttestKey, exchangeReceipt, metricBand } from "./metric.ts";
import { METRIC_RETRY_MS, REGISTRATION_CHECKS, type KeyRecord } from "./objects.ts";
import { storedReceiptFields, verifyReceipt } from "./receipt.ts";

/** The registered key's ID, base64, as `DCAppAttestService` gives it. */
export const KEY_HEADER = "X-Influx-Key";
/**
 * The assertion object, base64, over SHA-256 of the exact request body,
 * which names a fresh challenge.
 */
export const ASSERTION_HEADER = "X-Influx-Assertion";

/** A challenge: 32 random bytes, base64url. */
const CHALLENGE_FORMAT = /^[A-Za-z0-9_-]{43}$/;

export interface Options {
  /** Tests only: the roots to chain attestations and receipts to instead of Apple's. */
  roots?: Roots;
  /** Tests only: stands in for Apple's receipt exchange. */
  appleFetch?: typeof fetch;
}

function challenges(env: Env) {
  return env.CHALLENGES.get(env.CHALLENGES.idFromName("challenges"));
}

function attestedKey(env: Env, keyId: string) {
  return env.ATTESTED_KEYS.get(env.ATTESTED_KEYS.idFromName(keyId));
}

/**
 * Counts one attestation event for today, for `/oauth/usage`. `name` is a
 * fixed string or a Refusal's check name, never caller input. A failure to
 * count never fails the request.
 */
export async function note(env: Env, name: string): Promise<void> {
  try {
    const counter = env.DAILY_COUNT.get(env.DAILY_COUNT.idFromName("assertions"));
    await counter.fetch(new Request(`https://count/?event=${encodeURIComponent(name)}`, { method: "POST" }));
  } catch {
    // Only a count is lost.
  }
}

/** Whether the caller's address is over the shared per-minute limit. */
export async function rateLimited(request: Request, env: Env): Promise<boolean> {
  const address = request.headers.get("CF-Connecting-IP") ?? "unknown";
  return !(await env.RATE_LIMITER.limit({ key: address })).success;
}

/** POST /oauth/challenge: a single-use challenge, good for five minutes. */
export async function challenge(request: Request, env: Env): Promise<Response> {
  if (request.method !== "POST") return error(405, "method_not_allowed", { Allow: "POST" });
  if (!env.APPLE_TEAM_ID) return error(503, "not_configured");
  if (await rateLimited(request, env)) return error(429, "rate_limited", { "Retry-After": "60" });
  const value = base64url(crypto.getRandomValues(new Uint8Array(32)));
  const stored = await challenges(env).fetch(new Request(`https://challenges/issue?c=${value}`, { method: "POST" }));
  if (stored.status !== 204) return error(503, "unavailable");
  await note(env, "challenge");
  return json(200, { challenge: value }, { "Cache-Control": "no-store" });
}

/**
 * POST /oauth/register: checks a new key's App Attest attestation over a
 * challenge and stores the key. The iPhone and the Mac attest the same way,
 * except that a Mac key must also carry the trusted access policy.
 */
export async function register(request: Request, env: Env, options: Options): Promise<Response> {
  if (request.method !== "POST") return error(405, "method_not_allowed", { Allow: "POST" });
  const teamId = env.APPLE_TEAM_ID;
  if (!teamId) return error(503, "not_configured");
  if (await rateLimited(request, env)) return error(429, "rate_limited", { "Retry-After": "60" });
  const raw = await bodyBytes(request);
  const body = raw && jsonObject(raw);
  if (!body) return error(400, "invalid_request");
  const { platform, appId, keyId, attestation, challenge } = body;
  if ((platform !== "ios" && platform !== "mac") || typeof appId !== "string" || typeof keyId !== "string" || typeof attestation !== "string" || typeof challenge !== "string") {
    return error(400, "invalid_request");
  }
  // An app it doesn't attest is refused for good, before a challenge is
  // spent; until attestation is required, only as not accepted this time,
  // so the app asks without attestation rather than not at all.
  const environment = Object.hasOwn(ATTESTED_APPS, appId) ? ATTESTED_APPS[appId] : undefined;
  if (!environment) {
    await note(env, `register ${platform}: app ID not attested`);
    return env.REQUIRE_ATTESTATION === "true" ? error(403, "app_not_accepted") : error(401, "attestation_invalid");
  }
  // The challenge is spent before anything is checked, so a failed attempt
  // can't try it again.
  const consumed = CHALLENGE_FORMAT.test(challenge) && (await challenges(env).fetch(new Request(`https://challenges/consume?c=${challenge}`, { method: "POST" })));
  if (!consumed || consumed.status !== 204) {
    await note(env, `register ${platform}: bad challenge`);
    return error(400, "bad_challenge");
  }

  let keyBytes: Uint8Array;
  let verified: VerifiedAttestation;
  try {
    keyBytes = fromBase64(keyId);
    if (keyBytes.length !== 32) refuse("keyId: not 32 bytes");
    verified = await verifyAttestation(
      {
        attestation: fromBase64(attestation),
        keyId: keyBytes,
        challenge,
        appId: `${teamId}.${appId}`,
        environment,
        platform,
        minBundleVersion: env.MIN_BUNDLE_VERSION,
      },
      options.roots,
    );
  } catch (caught) {
    // A genuine app the Worker doesn't accept can't fix that with a new key.
    // Until attestation is required, that answer would stop the app signing
    // in at all, so it hears only that the attestation wasn't accepted, and
    // asks without it.
    if (caught instanceof Refusal) {
      await note(env, `register ${platform}: ${caught.message}`);
      const policy = caught.kind === "policy" && env.REQUIRE_ATTESTATION === "true";
      return policy ? error(403, "app_not_accepted") : error(401, "attestation_invalid");
    }
    throw caught;
  }
  // One spelling per key, whatever base64 the client sent.
  const canonical = toBase64(keyBytes);
  const read = await readMetric(env, options, {
    receipt: verified.receipt,
    credCert: verified.credCert,
    appId: `${teamId}.${appId}`,
    environment: verified.environment,
  });
  const receipt = read?.receipt ?? verified.receipt;
  const riskMetric = read?.riskMetric;
  const record: Omit<KeyRecord, "registeredAt" | "lastUsed"> = {
    publicKey: toBase64(verified.publicKey),
    counter: 0,
    platform,
    appId,
    teamId,
    category: verified.category,
    bundleVersion: verified.bundleVersion,
    credCert: toBase64(verified.credCert),
    environment: verified.environment,
    ...(verified.os ? { os: verified.os } : {}),
    checks: REGISTRATION_CHECKS,
    receipt: toBase64(receipt),
    ...(riskMetric === undefined ? {} : { riskMetric }),
    ...(env.APP_ATTEST_KEY && env.APP_ATTEST_KEY !== "off" ? { metricCheckedAt: Date.now() } : {}),
  };
  const stored = await attestedKey(env, canonical).fetch(new Request("https://key/", { method: "PUT", body: JSON.stringify(record) }));
  if (stored.status === 409) {
    await note(env, `register ${platform}: key conflict`);
    return error(409, "key_conflict");
  }
  await note(env, `register ${platform}: ok`);
  return json(201, { keyId: canonical }, { "Cache-Control": "no-store" });
}

/**
 * Apple's fraud metric for a key, when the Worker has an App Attest key:
 * `receipt` (the key's newest) is exchanged for one carrying the metric,
 * which the caller keeps in its place (Apple wants the newest kept).
 * Recorded, not yet acted on (ADR 0033). Nothing when the Worker has no
 * key or the exchange fails; it never throws, and the day's usage counts
 * say what happened.
 */
async function readMetric(
  env: Env,
  options: Options,
  input: { receipt: Uint8Array; credCert: Uint8Array; appId: string; environment: "production" | "development" },
): Promise<{ receipt: Uint8Array; riskMetric?: number } | undefined> {
  // "off" is how the deploy says the key was removed (README).
  if (!env.APP_ATTEST_KEY || env.APP_ATTEST_KEY === "off") return undefined;
  const key = appAttestKey(env.APP_ATTEST_KEY);
  if (!key) {
    await note(env, "metric: key malformed");
    return undefined;
  }
  // Apple refuses a token whose team doesn't match the receipt's.
  if (key.teamId !== env.APPLE_TEAM_ID) {
    await note(env, "metric: key for another team");
    return undefined;
  }
  const exchanged = await exchangeReceipt(key, input.receipt, input.environment, options.appleFetch);
  if ("failed" in exchanged) {
    await note(env, `metric: ${exchanged.failed}`);
    return undefined;
  }
  try {
    const fields = await verifyReceipt(
      { receipt: exchanged.receipt, appId: input.appId, credCert: input.credCert, type: "RECEIPT" },
      (options.roots ?? APPLE_ROOTS).receipt,
    );
    await note(env, `metric: ${metricBand(fields.riskMetric)}`);
    return fields.riskMetric === undefined ? { receipt: exchanged.receipt } : { receipt: exchanged.receipt, riskMetric: fields.riskMetric };
  } catch (caught) {
    if (caught instanceof Refusal) {
      await note(env, `metric: ${caught.message}`);
      return undefined;
    }
    await note(env, "metric: unexpected");
    return undefined;
  }
}

/** Whether a stored key may want its metric: it has none, and hasn't asked today. Its object has the final say. */
function wantsMetric(env: Env, record: KeyRecord, now: number): boolean {
  if (!env.APP_ATTEST_KEY || env.APP_ATTEST_KEY === "off" || record.riskMetric !== undefined) return false;
  return record.metricCheckedAt === undefined || now - record.metricCheckedAt >= METRIC_RETRY_MS;
}

/**
 * Reads the metric for a key registered before the Worker had an App Attest
 * key, or whose exchange failed, on one of its attested requests, at most
 * once a day. A key from before certificates were kept takes its
 * certificate and environment from its stored receipt, which the Worker
 * verified when it registered the key. Never fails the request.
 */
async function catchUpMetric(env: Env, options: Options, key: ReturnType<typeof attestedKey>, record: KeyRecord): Promise<void> {
  try {
    // Claimed first, in the key's object, so concurrent requests ask Apple once.
    const claimed = await key.fetch(new Request("https://key/metric-claim", { method: "POST", body: "{}" }));
    if (claimed.status !== 204) return;
    const receipt = fromBase64(record.receipt);
    const stored = record.credCert && record.environment ? undefined : storedReceiptFields(receipt);
    const credCert = record.credCert ? fromBase64(record.credCert) : stored!.credCert;
    const environment = record.environment ?? stored?.environment ?? ATTESTED_APPS[record.appId] ?? "production";
    const read = await readMetric(env, options, { receipt, credCert, appId: `${record.teamId}.${record.appId}`, environment });
    const update = { metricCheckedAt: Date.now(), ...(read ? { receipt: toBase64(read.receipt), riskMetric: read.riskMetric } : {}) };
    await key.fetch(new Request("https://key/metric", { method: "POST", body: JSON.stringify(update) }));
  } catch {
    await note(env, "metric: catch-up failed");
  }
}

/**
 * Whether an assertion request is attested: "none" without attestation
 * headers, "attested" when they check out (its challenge and counter are
 * then spent), "unknown" when the key isn't registered (never, or forgotten
 * after 90 idle days), "policy" when a genuine assertion comes from a build
 * it doesn't accept, and "refused" when anything else is wrong. The app
 * registers a new key after "unknown", gives up after "policy", and retries
 * with a fresh challenge after "refused".
 */
export async function callerAttestation(
  request: Request,
  raw: Uint8Array,
  body: Record<string, unknown>,
  env: Env,
  options: Options = {},
): Promise<"none" | "attested" | "unknown" | "policy" | "refused"> {
  const keyHeader = request.headers.get(KEY_HEADER);
  const assertionHeader = request.headers.get(ASSERTION_HEADER);
  if (keyHeader === null && assertionHeader === null) return "none";
  try {
    if (!keyHeader || !assertionHeader) refuse("headers: incomplete");
    // The body names a challenge from /oauth/challenge, and the assertion
    // signs the body, so each assertion is good for one request only.
    const { challenge } = body;
    if (typeof challenge !== "string" || !CHALLENGE_FORMAT.test(challenge)) refuse("challenge: missing");
    const keyBytes = fromBase64(keyHeader);
    if (keyBytes.length !== 32) refuse("keyId: not 32 bytes");
    const key = attestedKey(env, toBase64(keyBytes));
    const found = await key.fetch(new Request("https://key/"));
    if (found.status === 404) {
      await note(env, "assertion: key unknown");
      return "unknown";
    }
    if (found.status !== 200) refuse("keyId: unreadable");
    const record = (await found.json()) as KeyRecord;
    // Once attestation is required, a key registered under older checks
    // counts as unknown, so its install registers again under these.
    if (env.REQUIRE_ATTESTATION === "true" && (record.checks ?? 0) < REGISTRATION_CHECKS) {
      await note(env, "assertion: registered under older checks");
      return "unknown";
    }
    // An app since dropped from the list has no environment; the assertion
    // is still checked, so only a genuine one hears it isn't accepted.
    const environment = Object.hasOwn(ATTESTED_APPS, record.appId) ? ATTESTED_APPS[record.appId] : undefined;
    // A policy refusal comes from here, before the challenge is spent.
    const verified = await verifyAssertion({
      assertion: fromBase64(assertionHeader),
      clientData: raw,
      publicKey: fromBase64(record.publicKey),
      appId: `${record.teamId}.${record.appId}`,
      environment,
      minBundleVersion: env.MIN_BUNDLE_VERSION,
    });
    // Only a signed request spends a challenge, so nobody can burn another
    // install's challenges with forged requests.
    const consumed = await challenges(env).fetch(new Request(`https://challenges/consume?c=${challenge}`, { method: "POST" }));
    if (consumed.status !== 204) refuse("challenge: unknown, expired or spent");
    if (verified.counter <= record.counter) refuse("counter: not increasing");
    // The object refuses a counter that another request has passed since.
    const advanced = await key.fetch(
      new Request("https://key/advance", {
        method: "POST",
        body: JSON.stringify({ counter: verified.counter, category: verified.category, bundleVersion: verified.bundleVersion }),
      }),
    );
    if (advanced.status !== 204) refuse("counter: not increasing");
    if (wantsMetric(env, record, Date.now())) await catchUpMetric(env, options, key, record);
    return "attested";
  } catch (caught) {
    if (caught instanceof Refusal) {
      await note(env, `assertion: ${caught.message}`);
      return caught.kind === "policy" ? "policy" : "refused";
    }
    throw caught;
  }
}
