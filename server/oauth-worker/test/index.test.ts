// Run with: node --experimental-strip-types --test test/
import { test } from "node:test";
import assert from "node:assert/strict";
import worker, { clientId, clientMetadata, DailyCount, HOSTS, isPlainHttpsOrigin, SMOKE_AGENT, unattestedSource, type Env } from "../src/index.ts";
import { memoryState, memoryStorage } from "./helpers.ts";

const FLUX = "https://flux.bespokebits.dev";
const INFLUX = "https://influx.bespokebits.dev";

async function makeEnv(overrides: Partial<Env> = {}): Promise<{ env: Env; publicKey: CryptoKey }> {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const env: Env = {
    SIGNING_KEY_JWK: JSON.stringify(await crypto.subtle.exportKey("jwk", pair.privateKey)),
    SIGNING_KID: "key-1",
    ALLOWED_ISSUERS: "https://bsky.social https://pds.example.com:8443",
    DAILY_LIMIT: "2000",
    RATE_LIMITER: { limit: async () => ({ success: true }) },
    DAILY_COUNT: countNamespace(),
    ASSETS: { fetch: async () => new Response("asset") },
    ...overrides,
  };
  return { env, publicKey: pair.publicKey };
}

/** One DailyCount for every name, as the Worker only uses one. */
function countNamespace(): Env["DAILY_COUNT"] {
  const counter = new DailyCount(memoryState());
  return { idFromName: (name) => name, get: () => counter };
}

function post(body: unknown, origin = FLUX): Request {
  return new Request(`${origin}/oauth/assertion`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "CF-Connecting-IP": "203.0.113.7" },
    body: JSON.stringify(body),
  });
}

function decode(part: string): any {
  return JSON.parse(Buffer.from(part, "base64url").toString("utf8"));
}

test("signs an assertion for the issuer, verifiable with the published key", async () => {
  const { env, publicKey } = await makeEnv();
  const before = Math.floor(Date.now() / 1000);
  const response = await worker.fetch(post({ aud: "https://bsky.social" }), env);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("Cache-Control"), "no-store");
  const { client_assertion, kid } = (await response.json()) as { client_assertion: string; kid: string };
  assert.equal(kid, "key-1");

  const [header, claims, signature] = client_assertion.split(".");
  assert.deepEqual(decode(header), { alg: "ES256", kid: "key-1", typ: "JWT" });
  const body = decode(claims);
  assert.equal(body.iss, `${FLUX}/oauth/client-metadata.json`);
  assert.equal(body.sub, `${FLUX}/oauth/client-metadata.json`);
  assert.equal(body.aud, "https://bsky.social");
  assert.ok(body.iat >= before && body.exp === body.iat + 60);
  assert.equal(Buffer.from(body.jti, "base64url").length, 16);

  const valid = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" }, publicKey,
    Buffer.from(signature, "base64url"), new TextEncoder().encode(`${header}.${claims}`),
  );
  assert.ok(valid);

  // The JWKS publishes the same key, without its private part.
  const jwks = (await (await worker.fetch(new Request("https://flux.bespokebits.dev/oauth/jwks.json"), env)).json()) as { keys: any[] };
  assert.equal(jwks.keys.length, 1);
  assert.equal(jwks.keys[0].kid, "key-1");
  assert.equal(jwks.keys[0].d, undefined);
  const published = await crypto.subtle.importKey("jwk", jwks.keys[0], { name: "ECDSA", namedCurve: "P-256" }, true, ["verify"]);
  assert.deepEqual(await crypto.subtle.exportKey("jwk", published), await crypto.subtle.exportKey("jwk", publicKey));
});

test("every assertion has its own jti", async () => {
  const { env } = await makeEnv();
  const jtis = new Set<string>();
  for (let i = 0; i < 5; i++) {
    const { client_assertion } = (await (await worker.fetch(post({ aud: "https://bsky.social", kid: "key-1" }), env)).json()) as { client_assertion: string };
    jtis.add(decode(client_assertion.split(".")[1]).jti);
  }
  assert.equal(jtis.size, 5);
});

test("refuses to sign with a key other than the session's", async () => {
  const { env } = await makeEnv();
  const response = await worker.fetch(post({ aud: "https://bsky.social", kid: "key-0" }), env);
  assert.equal(response.status, 409);
  assert.deepEqual(await response.json(), { error: "key_retired" });
});

test("only signs for a plain https origin", async () => {
  const { env } = await makeEnv();
  for (const aud of ["http://bsky.social", "https://bsky.social/", "https://bsky.social/x", "https://u@bsky.social", "https://bsky.social?x", "bsky.social", 42]) {
    const response = await worker.fetch(post({ aud }), env);
    assert.equal(response.status, 400, String(aud));
  }
  assert.ok(isPlainHttpsOrigin("https://pds.example.com:8443"));
});

test("rate limits by address", async () => {
  const keys: string[] = [];
  const { env } = await makeEnv({ RATE_LIMITER: { limit: async ({ key }) => (keys.push(key), { success: false }) } });
  const response = await worker.fetch(post({ aud: "https://bsky.social" }), env);
  assert.equal(response.status, 429);
  assert.equal(response.headers.get("Retry-After"), "60");
  assert.deepEqual(keys, ["203.0.113.7"]);
});

test("only POST signs, and everything else is a static file", async () => {
  const { env } = await makeEnv();
  assert.equal((await worker.fetch(new Request("https://flux.bespokebits.dev/oauth/assertion"), env)).status, 405);
  assert.equal(await (await worker.fetch(new Request("https://flux.bespokebits.dev/oauth/callback"), env)).text(), "asset");
});

test("fails closed until the key and its ID are set", async () => {
  const { env } = await makeEnv();
  for (const overrides of [{ SIGNING_KID: "" }, { SIGNING_KEY_JWK: "" }, { SIGNING_KEY_JWK: "not json" }, { SIGNING_KEY_JWK: "{}" }] as Partial<Env>[]) {
    const broken = { ...env, ...overrides };
    for (const request of [post({ aud: "https://bsky.social" }), new Request("https://flux.bespokebits.dev/oauth/jwks.json")]) {
      const response = await worker.fetch(request, broken);
      assert.equal(response.status, 503);
      assert.deepEqual(await response.json(), { error: "not_configured" });
    }
  }
  // The static files don't need the key.
  assert.equal((await worker.fetch(new Request("https://flux.bespokebits.dev/oauth/client-metadata.json"), { ...env, SIGNING_KID: "" })).status, 200);
});

test("a body that isn't a JSON object is a bad request", async () => {
  const { env } = await makeEnv();
  for (const body of [null, [], 7, "aud"]) {
    const response = await worker.fetch(post(body), env);
    assert.equal(response.status, 400, JSON.stringify(body));
    assert.deepEqual(await response.json(), { error: "invalid_request" });
  }
});

test("only signs for the issuers it is told to", async () => {
  const { env } = await makeEnv();
  assert.equal((await worker.fetch(post({ aud: "https://pds.example.com:8443" }), env)).status, 200);
  for (const aud of ["https://evil.example", "https://bsky.social.evil.example", "https://pds.example.com"]) {
    const response = await worker.fetch(post({ aud }), env);
    assert.equal(response.status, 400, aud);
    assert.deepEqual(await response.json(), { error: "issuer_not_allowed" });
  }
  // With no list it signs for nobody.
  const response = await worker.fetch(post({ aud: "https://bsky.social" }), { ...env, ALLOWED_ISSUERS: "" });
  assert.equal(response.status, 400);
});

test("stops signing for the day at the daily limit", async () => {
  const { env } = await makeEnv({ DAILY_LIMIT: "2" });
  assert.equal((await worker.fetch(post({ aud: "https://bsky.social" }), env)).status, 200);
  assert.equal((await worker.fetch(post({ aud: "https://bsky.social" }), env)).status, 200);
  const response = await worker.fetch(post({ aud: "https://bsky.social" }), env);
  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), { error: "daily_limit" });
  // Refused requests don't count, and a missing limit signs nothing.
  for (const limit of ["", "0", "lots"]) {
    const { env: unset } = await makeEnv({ DAILY_LIMIT: limit });
    assert.equal((await worker.fetch(post({ aud: "https://bsky.social" }), unset)).status, 503, limit);
  }
});

test("the daily count starts again each day and forgets old days", async () => {
  const storage = memoryStorage();
  storage.map.set("2000-01-01", 5);
  const counter = new DailyCount(memoryState(storage));
  const take = () => counter.fetch(new Request("https://count/?limit=1", { method: "POST" }));
  assert.equal((await take()).status, 204);
  assert.equal((await take()).status, 429);
  assert.deepEqual([...storage.map.keys()], [new Date().toISOString().slice(0, 10)]);
});

test("usage reports today's count without counting", async () => {
  const { env } = await makeEnv();
  await worker.fetch(post({ aud: "https://bsky.social" }), env);
  const read = () => worker.fetch(new Request("https://flux.bespokebits.dev/oauth/usage"), env);
  for (let i = 0; i < 2; i++) {
    const response = await read();
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), {
      day: new Date().toISOString().slice(0, 10),
      count: 1,
      limit: 2000,
      attested: 0,
      unattested: 1,
      events: { "unattested: other": 1 },
    });
  }
  // It works before the key is configured, and only answers GET.
  assert.equal((await worker.fetch(new Request("https://flux.bespokebits.dev/oauth/usage"), { ...env, SIGNING_KID: "" })).status, 200);
  assert.equal((await worker.fetch(new Request("https://flux.bespokebits.dev/oauth/usage", { method: "POST" }), env)).status, 405);
});

test("serves exactly two hosts", () => {
  assert.deepEqual([...HOSTS], ["flux.bespokebits.dev", "influx.bespokebits.dev"]);
});

test("each host serves its own client metadata", async () => {
  const { env } = await makeEnv();
  for (const origin of [FLUX, INFLUX]) {
    const response = await worker.fetch(new Request(`${origin}/oauth/client-metadata.json`), env);
    assert.equal(response.status, 200);
    assert.match(response.headers.get("Content-Type") ?? "", /^application\/json/);
    const body = (await response.json()) as Record<string, unknown>;
    assert.equal(body.client_id, `${origin}/oauth/client-metadata.json`);
    assert.equal(body.client_id, clientId(origin));
    assert.equal(body.client_uri, origin);
    assert.deepEqual(body.redirect_uris, [`${origin}/oauth/callback`]);
    assert.equal(body.jwks_uri, `${origin}/oauth/jwks.json`);
  }
  // flux.bespokebits.dev's is exactly the file it served before the second host.
  assert.deepEqual(clientMetadata(FLUX), {
    client_id: "https://flux.bespokebits.dev/oauth/client-metadata.json",
    client_name: "Influx",
    client_uri: "https://flux.bespokebits.dev",
    application_type: "web",
    grant_types: ["authorization_code", "refresh_token"],
    response_types: ["code"],
    redirect_uris: ["https://flux.bespokebits.dev/oauth/callback"],
    scope: "atproto transition:generic",
    token_endpoint_auth_method: "private_key_jwt",
    token_endpoint_auth_signing_alg: "ES256",
    jwks_uri: "https://flux.bespokebits.dev/oauth/jwks.json",
    dpop_bound_access_tokens: true,
  });
  const posted = await worker.fetch(new Request(`${FLUX}/oauth/client-metadata.json`, { method: "POST" }), env);
  assert.equal(posted.status, 405);
});

test("both hosts sign with the same key, each as its own client", async () => {
  const { env, publicKey } = await makeEnv();
  const published: string[] = [];
  for (const origin of [FLUX, INFLUX]) {
    const response = await worker.fetch(post({ aud: "https://bsky.social" }, origin), env);
    assert.equal(response.status, 200);
    const { client_assertion, kid } = (await response.json()) as { client_assertion: string; kid: string };
    assert.equal(kid, "key-1");
    const [header, claims, signature] = client_assertion.split(".");
    const body = decode(claims);
    assert.equal(body.iss, `${origin}/oauth/client-metadata.json`);
    assert.equal(body.sub, `${origin}/oauth/client-metadata.json`);
    const valid = await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" }, publicKey,
      Buffer.from(signature, "base64url"), new TextEncoder().encode(`${header}.${claims}`),
    );
    assert.ok(valid, origin);
    published.push(await (await worker.fetch(new Request(`${origin}/oauth/jwks.json`), env)).text());
  }
  assert.equal(published[0], published[1]);
});

test("both hosts serve the AASA file as application/json", async () => {
  const seen: string[] = [];
  const { env } = await makeEnv({
    ASSETS: { fetch: async (request) => (seen.push(request.url), new Response("{}", { headers: { "Content-Type": "application/octet-stream" } })) },
  });
  for (const origin of [FLUX, INFLUX]) {
    const response = await worker.fetch(new Request(`${origin}/.well-known/apple-app-site-association`), env);
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("Content-Type"), "application/json");
    assert.equal(await response.text(), "{}");
  }
  assert.deepEqual(seen, [`${FLUX}/.well-known/apple-app-site-association`, `${INFLUX}/.well-known/apple-app-site-association`]);
});

test("the published AASA file is its template with the team filled in, for both app names", async () => {
  const { readFile } = await import("node:fs/promises");
  const published = JSON.parse(await readFile(new URL("../public/.well-known/apple-app-site-association", import.meta.url), "utf8"));
  const template = JSON.parse(await readFile(new URL("../apple-app-site-association.template.json", import.meta.url), "utf8"));
  const team = published.applinks.details[0].appIDs[0].split(".")[0];
  assert.deepEqual(JSON.parse(JSON.stringify(template).replaceAll("TEAMID.", `${team}.`)), published);
  // The renamed app takes the callback, and builds installed before the
  // rename keep it until no device runs one.
  const bundles = published.applinks.details[0].appIDs.map((id: string) => id.slice(team.length + 1));
  for (const prefix of ["dev.bespokebits.influx", "dev.bespokebits.flux"]) {
    for (const suffix of ["", ".dev", ".uitest"]) assert.ok(bundles.includes(prefix + suffix), prefix + suffix);
  }
  assert.deepEqual(published.webcredentials.apps, published.applinks.details[0].appIDs);
});

test("refuses any other host before serving or signing anything", async () => {
  let assetsServed = 0;
  let limited = 0;
  const { env } = await makeEnv({
    ASSETS: { fetch: async () => (assetsServed++, new Response("asset")) },
    RATE_LIMITER: { limit: async () => (limited++, { success: true }) },
  });
  const others = [
    "https://evil.example",
    "https://flux-oauth.example.workers.dev",
    "https://bespokebits.dev",
    "https://influx.bespokebits.dev.evil.example",
    "https://flux.bespokebits.dev:8443",
    "http://flux.bespokebits.dev",
  ];
  const paths = ["/oauth/client-metadata.json", "/oauth/jwks.json", "/oauth/callback", "/oauth/usage", "/.well-known/apple-app-site-association", "/"];
  for (const origin of others) {
    for (const path of paths) {
      const response = await worker.fetch(new Request(`${origin}${path}`), env);
      assert.equal(response.status, 421, `${origin}${path}`);
      assert.deepEqual(await response.json(), { error: "unknown_host" });
    }
    assert.equal((await worker.fetch(post({ aud: "https://bsky.social" }, origin), env)).status, 421, origin);
  }
  assert.equal(assetsServed, 0);
  assert.equal(limited, 0);
});

test("unattested requests are counted by where they came from", () => {
  const from = (agent?: string) =>
    unattestedSource(new Request(`${FLUX}/oauth/assertion`, { method: "POST", headers: agent ? { "User-Agent": agent } : {} }));
  assert.equal(from(SMOKE_AGENT), "unattested: deploy check");
  assert.equal(from("Influx/3 CFNetwork/3860.100.1 Darwin/27.2.0"), "unattested: Influx");
  assert.equal(from("Influx/1234567 CFNetwork/3860.100.1 Darwin/27.2.0"), "unattested: Influx");
  assert.equal(from("Influx%20Dev/1 CFNetwork/3860.100.1 Darwin/27.2.0"), "unattested: Influx Dev");
  // Anything else, however it names itself, is one bucket, so a caller cannot fill the day's events.
  assert.equal(from("Influx%20Evil/3 CFNetwork/1"), "unattested: other");
  assert.equal(from("curl/8.0"), "unattested: other");
  assert.equal(from(), "unattested: other");
});

test("an unattested request is still counted when attestation is required", async () => {
  const { env } = await makeEnv();
  const required = { ...env, REQUIRE_ATTESTATION: "true" };
  const request = post({ aud: "https://bsky.social" });
  request.headers.set("User-Agent", SMOKE_AGENT);
  const response = await worker.fetch(request, required);
  assert.equal(response.status, 401);
  assert.deepEqual(await response.json(), { error: "attestation_required" });
  const usage = (await (await worker.fetch(new Request(`${FLUX}/oauth/usage`), required)).json()) as { count: number; events: Record<string, number> };
  assert.equal(usage.count, 0);
  assert.deepEqual(usage.events, { "unattested: deploy check": 1 });
});
