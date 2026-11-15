// The OAuth Worker, on flux.bespokebits.dev and
// influx.bespokebits.dev. It serves the OAuth files, the client metadata for
// whichever of those hosts was asked, and signs client assertions for Influx,
// the confidential Bluesky client. It only signs: tokens never pass through
// it. Its state is a count of today's assertions, outstanding challenges and
// the App Attest keys of registered installs (ADR 0033). It also keeps the
// field performance reports attested TestFlight installs send (ADR 0034).

import { base64url, utf8 } from "./bytes.ts";
import { callerAttestation, challenge, note, register, type Options } from "./callers.ts";
import { bodyBytes, error, json, jsonObject } from "./http.ts";
import type { Kind, Namespace } from "./objects.ts";
import { report, reports } from "./perf.ts";

export { AttestedKey, Challenges, DailyCount, PerfReports } from "./objects.ts";
export { base64url } from "./bytes.ts";

export interface Env {
  /** Secret: the current private signing key, as a JWK (P-256, with `d`). */
  SIGNING_KEY_JWK: string;
  /** The current key's ID. */
  SIGNING_KID: string;
  /** The issuers it signs for, separated by spaces. Any other is refused. */
  ALLOWED_ISSUERS: string;
  /** How many assertions it signs in a UTC day, across all callers. */
  DAILY_LIMIT: string;
  /** The Apple team whose App IDs attested keys must name. */
  APPLE_TEAM_ID?: string;
  /** "true" refuses assertion requests without App Attest headers. */
  REQUIRE_ATTESTATION?: string;
  /** The lowest app bundle version it attests, dotted numbers; unset accepts any. */
  MIN_BUNDLE_VERSION?: string;
  /** Secret: the DeviceCheck key for Apple's fraud metric, JSON {"keyId", "teamId", "p8"}; unset asks Apple nothing. */
  APP_ATTEST_KEY?: string;
  RATE_LIMITER: { limit(options: { key: string }): Promise<{ success: boolean }> };
  DAILY_COUNT: Namespace;
  CHALLENGES: Namespace;
  ATTESTED_KEYS: Namespace;
  /** Field performance reports (ADR 0034). */
  PERF_REPORTS: Namespace;
  ASSETS: { fetch(request: Request): Promise<Response> };
}

/**
 * The hosts it serves, each its own OAuth client with the same signing key.
 * Every request runs the Worker first (`run_worker_first`), so any other host,
 * including workers.dev and preview URLs, is refused before a file is served.
 */
export const HOSTS = ["flux.bespokebits.dev", "influx.bespokebits.dev"] as const;

/** A host's client ID: the URL of its client metadata. */
export function clientId(origin: string): string {
  return `${origin}/oauth/client-metadata.json`;
}

/** A host's client metadata, whose `client_id` is the URL it is served at. */
export function clientMetadata(origin: string): Record<string, unknown> {
  return {
    client_id: clientId(origin),
    client_name: "Influx",
    client_uri: origin,
    application_type: "web",
    grant_types: ["authorization_code", "refresh_token"],
    response_types: ["code"],
    redirect_uris: [`${origin}/oauth/callback`],
    scope: "atproto transition:generic",
    token_endpoint_auth_method: "private_key_jwt",
    token_endpoint_auth_signing_alg: "ES256",
    jwks_uri: `${origin}/oauth/jwks.json`,
    dpop_bound_access_tokens: true,
  };
}

/** `https://<host>` when the request is for one of HOSTS, otherwise nothing. */
function servedOrigin(url: URL): string | undefined {
  if (url.protocol !== "https:") return undefined;
  return (HOSTS as readonly string[]).includes(url.host) ? `https://${url.host}` : undefined;
}

const AASA = "/.well-known/apple-app-site-association";
/** How long an assertion is good for. Influx uses each one at once. */
const LIFETIME = 60;

/** The Worker. Options exist for tests; the deployed Worker takes none. */
export function createWorker(options: Options = {}) {
  return {
    fetch: (request: Request, env: Env) => route(request, env, options),
  };
}

export default createWorker();

async function route(request: Request, env: Env, options: Options): Promise<Response> {
  const url = new URL(request.url);
  const origin = servedOrigin(url);
  if (!origin) return error(421, "unknown_host");
  const { pathname } = url;
  if (pathname === "/oauth/usage") return usage(request, env);
  if (pathname === "/oauth/challenge") return challenge(request, env);
  if (pathname === "/oauth/register") return register(request, env, options);
  if (pathname === "/perf/report") return report(request, env, options);
  if (pathname === "/perf/reports") return reports(request, env);
  if (pathname === "/oauth/client-metadata.json") return metadata(request, origin);
  if (pathname === AASA) return aasa(request, env);
  if (pathname !== "/oauth/assertion" && pathname !== "/oauth/jwks.json") return env.ASSETS.fetch(request);
  // Without a key there is nothing to sign with or publish; say so rather
  // than publish an empty key ID.
  const key = configuredKey(env);
  if (!key) return error(503, "not_configured");
  if (pathname === "/oauth/jwks.json") return json(200, jwks(key, env), { "Cache-Control": "max-age=300" });
  if (request.method !== "POST") return error(405, "method_not_allowed", { Allow: "POST" });
  return assertion(request, env, origin, options);
}

function metadata(request: Request, origin: string): Response {
  if (request.method !== "GET" && request.method !== "HEAD") return error(405, "method_not_allowed", { Allow: "GET, HEAD" });
  return json(200, clientMetadata(origin), { "Cache-Control": "public, max-age=0, must-revalidate" });
}

/**
 * The AASA file from public/, always as application/json: Apple ignores it
 * otherwise, and the file has no extension to type it by.
 */
async function aasa(request: Request, env: Env): Promise<Response> {
  const file = await env.ASSETS.fetch(request);
  if (!file.ok) return file;
  const headers = new Headers(file.headers);
  headers.set("Content-Type", "application/json");
  return new Response(file.body, { status: file.status, headers });
}

async function assertion(request: Request, env: Env, origin: string, options: Options): Promise<Response> {
  const address = request.headers.get("CF-Connecting-IP") ?? "unknown";
  if (!(await env.RATE_LIMITER.limit({ key: address })).success) {
    return error(429, "rate_limited", { "Retry-After": "60" });
  }
  // The exact bytes, because an App Attest assertion signs them.
  const raw = await bodyBytes(request);
  const body = raw && jsonObject(raw);
  if (!body) return error(400, "invalid_request");
  const { aud, kid } = body;
  if (typeof aud !== "string" || !isPlainHttpsOrigin(aud)) return error(400, "invalid_aud");
  // Until callers are attested, anyone can ask, so it signs only for
  // the servers Influx is known to use.
  if (!env.ALLOWED_ISSUERS?.split(/\s+/).includes(aud)) return error(400, "issuer_not_allowed");
  if (kid !== undefined && kid !== null && typeof kid !== "string") return error(400, "invalid_request");
  // A session must keep the key it started with; signing with another
  // would end it, so a retired key is a refusal, never a fallback.
  if (typeof kid === "string" && kid !== env.SIGNING_KID) return error(409, "key_retired");

  // Phase 1 of ADR 0033: check attestation whenever it is sent, and require
  // it only once REQUIRE_ATTESTATION is on.
  const attestation = await callerAttestation(request, raw, body, env, options);
  // Both are signed as unattested while attestation is optional, and refused
  // once it is required; either way, count where they came from.
  if (attestation === "none" || attestation === "policy") await note(env, unattestedSource(request));
  // An unregistered key gets its own answer, so the app knows to register
  // a new one rather than retry.
  if (attestation === "unknown") return error(401, "key_unknown");
  // A build it doesn't accept: neither a new key nor a retry will help. Until
  // attestation is required, it is signed for like any unattested caller.
  if (attestation === "policy" && env.REQUIRE_ATTESTATION === "true") return error(403, "app_not_accepted");
  if (attestation === "refused") return error(401, "attestation_required");
  if (attestation === "none" && env.REQUIRE_ATTESTATION === "true") return error(401, "attestation_required");

  if (!(await underDailyLimit(env, attestation === "attested" ? "attested" : "unattested"))) {
    return error(503, "daily_limit", { "Retry-After": "3600" });
  }

  const now = Math.floor(Date.now() / 1000);
  // Each host is its own client, so the assertion names the one asked.
  const jwt = await sign(env, {
    iss: clientId(origin),
    sub: clientId(origin),
    aud,
    jti: base64url(crypto.getRandomValues(new Uint8Array(16))),
    iat: now,
    exp: now + LIFETIME,
  });
  return json(200, { client_assertion: jwt, kid: env.SIGNING_KID }, { "Cache-Control": "no-store" });
}

/** The User-Agent the deploy's smoke check sends, so its requests are told apart. */
export const SMOKE_AGENT = "influx-deploy-check";

/**
 * Who asked without attestation, for the day's counts, so the week before
 * attestation is required can tell real installs from deploys (ADR 0033).
 * The smoke check names itself, and the app sends URLSession's default
 * User-Agent, "<bundle name>/<build> CFNetwork/…". Anyone can send either,
 * so it is used for nothing but the count. The names are a fixed set of six,
 * with no build number, so a caller cannot fill the day's events with names.
 */
export function unattestedSource(request: Request): string {
  const agent = request.headers.get("User-Agent") ?? "";
  if (agent === SMOKE_AGENT) return "unattested: deploy check";
  const app = /^Influx(%20(?:Dev|Test|Perf))?\/\d+ CFNetwork\//.exec(agent);
  if (!app) return "unattested: other";
  return `unattested: Influx${app[1] ? ` ${app[1].slice(3)}` : ""}`;
}

/**
 * Today's count against the daily limit, for a volume alert, and how many
 * of those were attested, with the day's attestation events (challenges,
 * registrations, and refusals by the check that failed) to show whether
 * installs attest. It holds nothing secret, and reading it counts nothing.
 */
async function usage(request: Request, env: Env): Promise<Response> {
  if (request.method !== "GET") return error(405, "method_not_allowed", { Allow: "GET" });
  const limit = Number.parseInt(env.DAILY_LIMIT ?? "", 10);
  const counter = env.DAILY_COUNT.get(env.DAILY_COUNT.idFromName("assertions"));
  const { day, count, attested, unattested, events } = (await (await counter.fetch(new Request("https://count/"))).json()) as {
    day: string;
    count: number;
    attested: number;
    unattested: number;
    events: Record<string, number>;
  };
  return json(200, { day, count, limit: limit > 0 ? limit : 0, attested, unattested, events }, { "Cache-Control": "no-store" });
}

/** Counts one more assertion today, of its kind; false once the day's limit is reached. */
async function underDailyLimit(env: Env, kind: Kind): Promise<boolean> {
  const limit = Number.parseInt(env.DAILY_LIMIT ?? "", 10);
  // Without a sane limit, sign nothing rather than everything.
  if (!(limit > 0)) return false;
  const counter = env.DAILY_COUNT.get(env.DAILY_COUNT.idFromName("assertions"));
  const response = await counter.fetch(new Request(`https://count/?limit=${limit}&kind=${kind}`, { method: "POST" }));
  return response.status === 204;
}

/** An authorization server's issuer: `https://host[:port]` and nothing else. */
export function isPlainHttpsOrigin(value: string): boolean {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    return false;
  }
  // The origin drops any path, query, fragment or credentials, so a value
  // with any of those (or a trailing slash) doesn't match it.
  return url.protocol === "https:" && value === url.origin;
}

/** The signing key, if the Worker has one and a key ID for it. */
function configuredKey(env: Env): JsonWebKey | undefined {
  if (!env.SIGNING_KID) return undefined;
  try {
    const jwk = JSON.parse(env.SIGNING_KEY_JWK ?? "") as JsonWebKey;
    return jwk.kty === "EC" && jwk.crv === "P-256" && jwk.x && jwk.y && jwk.d ? jwk : undefined;
  } catch {
    return undefined;
  }
}

function jwks(key: JsonWebKey, env: Env): { keys: JsonWebKey[] } {
  const { kty, crv, x, y } = key;
  return { keys: [{ kty, crv, x, y, kid: env.SIGNING_KID, alg: "ES256", use: "sig" }] };
}

let cached: { source: string; key: CryptoKey } | undefined;

async function signingKey(env: Env): Promise<CryptoKey> {
  if (cached?.source !== env.SIGNING_KEY_JWK) {
    const jwk = JSON.parse(env.SIGNING_KEY_JWK) as JsonWebKey;
    const key = await crypto.subtle.importKey("jwk", jwk, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
    cached = { source: env.SIGNING_KEY_JWK, key };
  }
  return cached.key;
}

async function sign(env: Env, claims: Record<string, unknown>): Promise<string> {
  const header = { alg: "ES256", kid: env.SIGNING_KID, typ: "JWT" };
  const input = `${base64url(utf8(JSON.stringify(header)))}.${base64url(utf8(JSON.stringify(claims)))}`;
  // WebCrypto's ECDSA signature is r || s, which is what JWS wants.
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, await signingKey(env), utf8(input));
  return `${input}.${base64url(new Uint8Array(signature))}`;
}
