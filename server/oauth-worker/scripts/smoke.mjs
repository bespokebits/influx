// Post-deploy check of every host the Worker serves: node scripts/smoke.mjs <kid>
// Prints only public values (status codes, content types, the kid).
// Retries for up to three minutes while a new version (or a newly attached
// custom domain) propagates.

import { readFileSync } from "node:fs";

// Space-separated; both hosts by default. INFLUX_OAUTH_BASES is the name
// going forward; the FLUX_ and singular names keep working.
const BASES = (
  process.env.INFLUX_OAUTH_BASES ??
  process.env.FLUX_OAUTH_BASES ??
  process.env.INFLUX_OAUTH_BASE ??
  process.env.FLUX_OAUTH_BASE ??
  "https://flux.bespokebits.dev https://influx.bespokebits.dev"
)
  .split(/\s+/)
  .filter(Boolean);
const kid = process.argv[2];
// The deployed setting, from the config this deploy used. Once attestation
// is required (ADR 0033) the check cannot attest, so it confirms that an
// unattested request is refused instead of checking a signature.
const required = /^REQUIRE_ATTESTATION\s*=\s*"true"/m.test(
  readFileSync(new URL("../wrangler.toml", import.meta.url), "utf8"),
);
// Names the check, so the Worker counts its requests apart from the app's.
const AGENT = "influx-deploy-check";
if (!kid) {
  console.error("usage: node scripts/smoke.mjs <kid>");
  process.exit(2);
}

function check(condition, message) {
  if (!condition) throw new Error(message);
}

const deadline = Date.now() + 180_000;
// Every request and body read is bounded by what is left of the deadline, so
// a stalled response cannot hold the job past it (and past the rollback).
function remaining() {
  return AbortSignal.timeout(Math.max(1, deadline - Date.now()));
}

async function get(BASE, path) {
  const response = await fetch(BASE + path, { redirect: "manual", signal: remaining(), headers: { "User-Agent": AGENT } });
  const type = response.headers.get("content-type") ?? "";
  console.log(`GET ${BASE}${path} -> ${response.status} ${type}`);
  check(response.status === 200, `${path}: expected 200 with no redirect, got ${response.status}`);
  return { response, type };
}

function decode(part) {
  return JSON.parse(Buffer.from(part, "base64url").toString("utf8"));
}

async function once(BASE) {
  const metadata = await get(BASE, "/oauth/client-metadata.json");
  check(metadata.type.startsWith("application/json"), "client metadata is not application/json");
  const body = await metadata.response.json();
  check(body.client_id === `${BASE}/oauth/client-metadata.json`, "client_id is not the metadata URL");
  check(body.jwks_uri === `${BASE}/oauth/jwks.json`, "jwks_uri is not the JWKS URL");
  check(
    Array.isArray(body.redirect_uris) && body.redirect_uris.length === 1 && body.redirect_uris[0] === `${BASE}/oauth/callback`,
    "redirect_uris is not this host's callback",
  );

  await get(BASE, "/oauth/callback");

  const jwksResponse = await get(BASE, "/oauth/jwks.json");
  const jwksText = await jwksResponse.response.text();
  const jwks = JSON.parse(jwksText);
  check(Array.isArray(jwks.keys) && jwks.keys.length === 1, "JWKS must publish exactly one key");
  const [key] = jwks.keys;
  check(key.kid === kid, `JWKS kid ${key.kid} is not ${kid}`);
  check(key.d === undefined, "JWKS publishes a private key");
  check(key.kty === "EC" && key.crv === "P-256" && key.alg === "ES256", "JWKS key is not ES256");

  const aasa = await get(BASE, "/.well-known/apple-app-site-association");
  check(aasa.type.startsWith("application/json"), `AASA is ${aasa.type || "untyped"}, not application/json`);
  await aasa.response.json();

  const signed = await fetch(`${BASE}/oauth/assertion`, {
    method: "POST",
    redirect: "manual",
    signal: remaining(),
    headers: { "Content-Type": "application/json", "User-Agent": AGENT },
    body: JSON.stringify({ aud: "https://bsky.social" }),
  });
  console.log(`POST ${BASE}/oauth/assertion (bsky.social) -> ${signed.status}`);
  if (required) {
    check(signed.status === 401, `unattested assertion for bsky.social: ${signed.status}, expected 401`);
    const { error } = await signed.json();
    check(error === "attestation_required", `unattested assertion refused with ${error}, not attestation_required`);
  } else {
    await checkSigned(signed, body, key);
  }

  const refused = await fetch(`${BASE}/oauth/assertion`, {
    method: "POST",
    redirect: "manual",
    signal: remaining(),
    headers: { "Content-Type": "application/json", "User-Agent": AGENT },
    body: JSON.stringify({ aud: "https://example.com" }),
  });
  console.log(`POST ${BASE}/oauth/assertion (example.com) -> ${refused.status}`);
  check(refused.status === 400, `assertion for another issuer: ${refused.status}, expected 400`);
  return jwksText;
}

/** Checks a signed assertion against this host's metadata and published key. */
async function checkSigned(signed, body, key) {
  check(signed.status === 200, `assertion for bsky.social: ${signed.status}`);
  const { client_assertion: jwt, kid: usedKid } = await signed.json();
  check(usedKid === kid, "assertion signed with another kid");
  const [header, claims, signature] = jwt.split(".");
  const h = decode(header);
  const c = decode(claims);
  check(h.alg === "ES256" && h.kid === kid, "assertion header is not ES256 with the current kid");
  check(c.aud === "https://bsky.social", "assertion aud is wrong");
  check(c.iss === body.client_id && c.sub === body.client_id, "assertion iss/sub is not this host's client_id");
  check(c.exp - c.iat <= 60 && c.exp > Math.floor(Date.now() / 1000), "assertion lifetime is not at most 60 s");
  check(Buffer.from(c.jti, "base64url").length >= 16, "jti is shorter than 128 bits");
  const publicKey = await crypto.subtle.importKey("jwk", key, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
  const valid = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" }, publicKey,
    Buffer.from(signature, "base64url"), new TextEncoder().encode(`${header}.${claims}`),
  );
  check(valid, "assertion does not verify with the published key");
}

for (;;) {
  try {
    const published = [];
    for (const base of BASES) published.push(await once(base));
    check(published.every((text) => text === published[0]), "the hosts publish different JWKS");
    console.log(`${BASES.join(" and ")} serve kid ${kid}`);
    break;
  } catch (error) {
    if (Date.now() > deadline) {
      console.error(`smoke failed: ${error.message}`);
      process.exit(1);
    }
    console.log(`not yet: ${error.message}; retrying in 10 s`);
    await new Promise((resolve) => setTimeout(resolve, 10_000));
  }
}
