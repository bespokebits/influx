// Caller attestation (ADR 0033): challenges, App Attest registration for the
// iPhone and the Mac, attested assertion requests, and the parsers under
// them. Everything is signed by a stand-in PKI; nothing calls Apple.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createWorker, type Env } from "../src/index.ts";
import { verifyAssertion, verifyAttestation, type Attestation, type Roots } from "../src/attest.ts";
import { Refusal } from "../src/bytes.ts";
import { decodeCbor } from "../src/cbor.ts";
import { ecdsaSignatureToRaw, parseCertificate, readElement } from "../src/der.ts";
import { AttestedKey, KEY_IDLE_LIMIT_MS } from "../src/objects.ts";
import { storedReceiptFields, verifyReceipt, type ReceiptFields } from "../src/receipt.ts";
import {
  AAGUID_DEVELOPMENT,
  AAGUID_PRODUCTION,
  attestEnv,
  b64,
  certificate,
  cbor,
  concat,
  DEBUG,
  PREVIEW,
  ecKeys,
  enc,
  makeAssertion,
  makeAttestation,
  makePki,
  makeReceipt,
  makeReceiptPki,
  memoryState,
  RELEASE,
  sha256,
  TEAM,
  TRUSTED_ACL_BLOB,
  type Keys,
  type Launch,
  type ReceiptOptions,
} from "./helpers.ts";

const ORIGIN = "https://influx.bespokebits.dev";
const pki = await makePki();
const worker = createWorker({ roots: pki.roots });

async function newChallenge(env: Env): Promise<string> {
  const response = await worker.fetch(new Request(`${ORIGIN}/oauth/challenge`, { method: "POST" }), env);
  assert.equal(response.status, 200);
  return ((await response.json()) as { challenge: string }).challenge;
}

function registerRequest(body: unknown): Request {
  return new Request(`${ORIGIN}/oauth/register`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "CF-Connecting-IP": "203.0.113.7" },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

/** Registers a fresh key and returns what it needs to make assertions. */
async function registered(env: Env, platform: "ios" | "mac" = "ios", bundle = RELEASE): Promise<{ keyId: string; leaf: Keys; appId: string }> {
  const challenge = await newChallenge(env);
  const made = await makeAttestation(pki, { challenge, bundle, aclBlob: platform === "mac" ? TRUSTED_ACL_BLOB : undefined });
  const response = await worker.fetch(
    registerRequest({ platform, appId: bundle, keyId: b64(made.keyId), attestation: b64(made.attestation), challenge }),
    env,
  );
  assert.equal(response.status, 201);
  const { keyId } = (await response.json()) as { keyId: string };
  return { keyId, leaf: made.leaf, appId: `${TEAM}.${bundle}` };
}

/**
 * An assertion request as the app makes one: a fresh challenge in the body
 * (unless `fields` sets or clears `challenge`) and an assertion over it.
 */
async function attestedRequest(
  env: Env,
  key: { keyId: string; leaf: Keys; appId: string },
  counter: number,
  fields: Record<string, unknown> = {},
  launch: Launch = {},
): Promise<Request> {
  const body = enc.encode(JSON.stringify({ aud: "https://bsky.social", challenge: await newChallenge(env), ...fields }));
  const assertion = await makeAssertion(key.leaf, body, counter, key.appId, launch);
  return new Request(`${ORIGIN}/oauth/assertion`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Influx-Key": key.keyId, "X-Influx-Assertion": b64(assertion) },
    body,
  });
}

function plainRequest(): Request {
  return new Request(`${ORIGIN}/oauth/assertion`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ aud: "https://bsky.social" }),
  });
}

async function expectError(response: Response, status: number, code: string) {
  assert.equal(response.status, status);
  assert.deepEqual(await response.json(), { error: code });
}

/** A valid attestation's input, for checking verifyAttestation directly. */
async function input(
  options: Parameters<typeof makeAttestation>[1] & {
    requestKeyId?: Uint8Array;
    appId?: string;
    environment?: "production" | "development";
    platform?: "ios" | "mac";
    minBundleVersion?: string;
  },
): Promise<Attestation> {
  const made = await makeAttestation(pki, options);
  return {
    attestation: made.attestation,
    keyId: options.requestKeyId ?? made.keyId,
    challenge: options.challenge,
    appId: options.appId ?? `${TEAM}.${options.bundle ?? RELEASE}`,
    environment: options.environment ?? (options.bundle === DEBUG ? "development" : "production"),
    platform: options.platform ?? "ios",
    // As deployed, unless a test clears it.
    minBundleVersion: "minBundleVersion" in options ? options.minBundleVersion : "0.1.0",
  };
}

/** That a check refuses, for the reason given. */
function refusedFor(check: Promise<unknown>, reason: RegExp, label?: string) {
  return assert.rejects(check, (e: unknown) => e instanceof Refusal && reason.test(e.message), label);
}

const CHALLENGE = "c".repeat(43);

// Challenges

test("a challenge is 32 random bytes, and only POST makes one", async () => {
  const { env, challenges } = await attestEnv();
  const one = await newChallenge(env);
  const two = await newChallenge(env);
  assert.notEqual(one, two);
  assert.equal(Buffer.from(one, "base64url").length, 32);
  assert.match(one, /^[A-Za-z0-9_-]{43}$/);
  assert.ok(challenges.storage("challenges").map.has(one));
  assert.equal((await worker.fetch(new Request(`${ORIGIN}/oauth/challenge`), env)).status, 405);
});

test("challenges are rate limited by address", async () => {
  const { env } = await attestEnv({ RATE_LIMITER: { limit: async () => ({ success: false }) } });
  await expectError(await worker.fetch(new Request(`${ORIGIN}/oauth/challenge`, { method: "POST" }), env), 429, "rate_limited");
  await expectError(await worker.fetch(registerRequest({}), env), 429, "rate_limited");
});

test("without a team ID, attestation is not configured", async () => {
  const { env } = await attestEnv({ APPLE_TEAM_ID: "" });
  await expectError(await worker.fetch(new Request(`${ORIGIN}/oauth/challenge`, { method: "POST" }), env), 503, "not_configured");
  await expectError(await worker.fetch(registerRequest({}), env), 503, "not_configured");
});

// Registration

test("registers an iPhone key with a valid attestation", async () => {
  const { env, keys } = await attestEnv();
  const { keyId, leaf } = await registered(env, "ios");
  assert.equal(Buffer.from(keyId, "base64").length, 32);
  assert.deepEqual(Buffer.from(keyId, "base64"), Buffer.from(await sha256(leaf.point)));
  const record = keys.storage(keyId).map.get("key") as Record<string, unknown>;
  assert.equal(record.publicKey, b64(leaf.point));
  assert.equal(record.counter, 0);
  assert.equal(record.platform, "ios");
  assert.equal(record.appId, RELEASE);
  assert.equal(record.teamId, TEAM);
  assert.ok(typeof record.registeredAt === "number" && record.lastUsed === record.registeredAt);
});

test("a Mac registers through the same App Attest checks", async () => {
  const { env, keys } = await attestEnv();
  const { keyId } = await registered(env, "mac");
  assert.equal((keys.storage(keyId).map.get("key") as Record<string, unknown>).platform, "mac");
  // The debug app, in the development environment, too.
  await registered(env, "mac", DEBUG);
  // And a Mac attestation that fails a check is refused like an iPhone's.
  for (const platform of ["mac", "ios"]) {
    const challenge = await newChallenge(env);
    const made = await makeAttestation(pki, { challenge, nonce: new Uint8Array(32), aclBlob: TRUSTED_ACL_BLOB });
    const response = await worker.fetch(registerRequest({ platform, appId: RELEASE, keyId: b64(made.keyId), attestation: b64(made.attestation), challenge }), env);
    await expectError(response, 401, "attestation_invalid");
  }
});

test("a Mac key must carry the trusted access policy; an iPhone key's own is not checked", async () => {
  const { env } = await attestEnv({ REQUIRE_ATTESTATION: "true" });
  const register = async (platform: "ios" | "mac", aclBlob?: Uint8Array) => {
    const challenge = await newChallenge(env);
    const made = await makeAttestation(pki, { challenge, aclBlob });
    return worker.fetch(registerRequest({ platform, appId: RELEASE, keyId: b64(made.keyId), attestation: b64(made.attestation), challenge }), env);
  };
  const other = TRUSTED_ACL_BLOB.slice();
  other[other.length - 1] = 0x02;
  assert.equal((await register("mac", TRUSTED_ACL_BLOB)).status, 201);
  // A key's access policy is the device's, so a new key won't change it.
  await expectError(await register("mac"), 403, "app_not_accepted");
  await expectError(await register("mac", other), 403, "app_not_accepted");
  assert.equal((await register("ios")).status, 201);
  // An iPhone key carries an access policy of its own (seen on iOS 27).
  assert.equal((await register("ios", other)).status, 201);
  // The reasons, checked directly, all policy.
  const reason = (made: Promise<Attestation>, pattern: RegExp) =>
    assert.rejects(
      made.then((i) => verifyAttestation(i, pki.roots)),
      (e: unknown) => e instanceof Refusal && e.kind === "policy" && pattern.test(e.message),
    );
  await reason(input({ challenge: CHALLENGE, platform: "mac" }), /aclBlob: missing/);
  await reason(input({ challenge: CHALLENGE, platform: "mac", aclBlob: other }), /aclBlob: untrusted/);
  await verifyAttestation(await input({ challenge: CHALLENGE, platform: "ios", aclBlob: other }), pki.roots);
  await verifyAttestation(await input({ challenge: CHALLENGE, platform: "ios", aclBlob: TRUSTED_ACL_BLOB }), pki.roots);
});

test("a key its certificate says was made on macOS gets the Mac's check, whatever the caller claims", async () => {
  const other = TRUSTED_ACL_BLOB.slice();
  other[other.length - 1] = 0x02;
  const check = (platform: "ios" | "mac", deviceOs?: string | Uint8Array, aclBlob = other) =>
    input({ challenge: CHALLENGE, platform, deviceOs, aclBlob }).then((i) => verifyAttestation(i, pki.roots));
  // A Mac calling itself an iPhone still needs the trusted policy.
  await refusedFor(check("ios", "macosx"), /aclBlob: untrusted policy/);
  assert.equal((await check("ios", "macosx", TRUSTED_ACL_BLOB)).os, "macosx");
  // An iPhone's own policy is fine, and the OS is kept.
  assert.equal((await check("ios", "iphoneos")).os, "iphoneos");
  // An extension it can't read changes nothing: the claim decides.
  for (const raw of [new Uint8Array([0x30, 0x03, 0x02, 0x01, 0x00]), new Uint8Array([0x30, 0x02, 0xbf, 0x88]), new Uint8Array([1, 2, 3])]) {
    assert.equal((await check("ios", raw)).os, undefined);
  }
});

test("once attestation is required, a key registered under older checks registers again", async () => {
  const { env, keys } = await attestEnv({ REQUIRE_ATTESTATION: "true" });
  const key = await registered(env);
  assert.equal((keys.storage(key.keyId).map.get("key") as { checks?: number }).checks, 1);
  assert.equal((await worker.fetch(await attestedRequest(env, key, 1), env)).status, 200);
  // A record from before checks were counted.
  delete (keys.storage(key.keyId).map.get("key") as { checks?: number }).checks;
  await expectError(await worker.fetch(await attestedRequest(env, key, 2), env), 401, "key_unknown");
  // Until then it is still signed for.
  assert.equal((await worker.fetch(await attestedRequest({ ...env, REQUIRE_ATTESTATION: "false" }, key, 3), { ...env, REQUIRE_ATTESTATION: "false" })).status, 200);
});

test("registering a key again keeps its counter", async () => {
  // App Attest attests a key once, so this is a retry after a lost answer,
  // and must not reset the counter or old assertions would count again.
  const object = new AttestedKey(memoryState());
  const put = (publicKey: string) =>
    object.fetch(new Request("https://key/", { method: "PUT", body: JSON.stringify({ publicKey, counter: 0, platform: "ios", appId: RELEASE, teamId: TEAM }) }));
  const advance = (counter: number) => object.fetch(new Request("https://key/advance", { method: "POST", body: JSON.stringify({ counter }) }));
  assert.equal((await put("A")).status, 201);
  assert.equal((await advance(7)).status, 204);
  assert.equal((await put("A")).status, 200);
  assert.equal((await put("B")).status, 409);
  assert.equal((await advance(7)).status, 409);
  assert.equal((await advance(8)).status, 204);
});

test("refuses an app it doesn't attest and a body it can't read", async () => {
  const { env, challenges } = await attestEnv({ REQUIRE_ATTESTATION: "true" });
  const challenge = await newChallenge(env);
  const made = await makeAttestation(pki, { challenge, bundle: "com.example.other" });
  const other = () =>
    registerRequest({ platform: "ios", appId: "com.example.other", keyId: b64(made.keyId), attestation: b64(made.attestation), challenge });
  await expectError(await worker.fetch(other(), env), 403, "app_not_accepted");
  // Refused before its challenge was spent.
  assert.ok(challenges.storage("challenges").map.has(challenge));
  // Until attestation is required, it is only not accepted this time.
  await expectError(await worker.fetch(other(), { ...env, REQUIRE_ATTESTATION: "false" }), 401, "attestation_invalid");
  for (const body of ["not json", "null", "[]", { platform: "android", appId: RELEASE, keyId: "a", attestation: "a", challenge }, { platform: "ios" }]) {
    await expectError(await worker.fetch(registerRequest(body), env), 400, "invalid_request");
  }
  assert.equal((await worker.fetch(new Request(`${ORIGIN}/oauth/register`), env)).status, 405);
});

test("a challenge is single use, expires and must be one it issued", async () => {
  const { env, challenges } = await attestEnv();
  const register = async (challenge: string) => {
    const made = await makeAttestation(pki, { challenge });
    return worker.fetch(registerRequest({ platform: "ios", appId: RELEASE, keyId: b64(made.keyId), attestation: b64(made.attestation), challenge }), env);
  };
  const challenge = await newChallenge(env);
  assert.equal((await register(challenge)).status, 201);
  await expectError(await register(challenge), 400, "bad_challenge");

  const expired = await newChallenge(env);
  challenges.storage("challenges").map.set(expired, Date.now() - 1);
  await expectError(await register(expired), 400, "bad_challenge");
  assert.equal(challenges.storage("challenges").map.has(expired), false);

  await expectError(await register(CHALLENGE), 400, "bad_challenge");
  await expectError(await register("short"), 400, "bad_challenge");

  // A failed attestation still spends its challenge.
  const spent = await newChallenge(env);
  const made = await makeAttestation(pki, { challenge: spent, counter: 1 });
  const body = { platform: "ios", appId: RELEASE, keyId: b64(made.keyId), attestation: b64(made.attestation), challenge: spent };
  await expectError(await worker.fetch(registerRequest(body), env), 401, "attestation_invalid");
  await expectError(await worker.fetch(registerRequest(body), env), 400, "bad_challenge");
});

test("a valid attestation passes on its own", async () => {
  const { publicKey } = await verifyAttestation(await input({ challenge: CHALLENGE }), pki.roots);
  assert.equal(publicKey.length, 65);
  await verifyAttestation(await input({ challenge: CHALLENGE, bundle: DEBUG }), pki.roots);
});

test("each attestation check fails on its own", async () => {
  const rogue = await ecKeys("P-384");
  const otherRoot = await makePki();
  const cases: [string, Promise<Attestation>, RegExp, Roots?][] = [
    [
      "an intermediate not signed by the root",
      input({
        challenge: CHALLENGE,
        intermediateCertificate: await certificate({ subject: "Test App Attestation CA 1", issuer: "Test App Attestation Root CA", spki: pki.intermediate.spki, signer: rogue.privateKey }),
      }),
      /chain: signature/,
    ],
    ["another root with the same name", input({ challenge: CHALLENGE }), /chain: signature/, { ...pki.roots, appAttest: otherRoot.rootCertificate }],
    ["an expired leaf", input({ challenge: CHALLENGE, leafNotAfter: new Date(Date.now() - 1000) }), /out of date/],
    ["a nonce for something else", input({ challenge: CHALLENGE, nonce: new Uint8Array(32).fill(9) }), /nonce: mismatch/],
    ["a challenge other than the one hashed", input({ challenge: CHALLENGE }).then((i) => ({ ...i, challenge: "d".repeat(43) })), /nonce: mismatch/],
    ["a key ID that isn't the leaf's key", input({ challenge: CHALLENGE, keyId: new Uint8Array(32).fill(1) }), /keyId/],
    ["another team's App ID", input({ challenge: CHALLENGE, team: "OTHERTEAM1" }), /rpIdHash/],
    ["another app's App ID", input({ challenge: CHALLENGE, appId: `${TEAM}.${DEBUG}` }), /rpIdHash/],
    ["a used key (counter not zero)", input({ challenge: CHALLENGE, counter: 1 }), /authData: counter/],
    ["the release app in development", input({ challenge: CHALLENGE, aaguid: AAGUID_DEVELOPMENT }), /aaguid/],
    ["the debug app in neither environment", input({ challenge: CHALLENGE, bundle: DEBUG, aaguid: new Uint8Array(16) }), /aaguid/],
    ["a credential ID for another key", input({ challenge: CHALLENGE, credentialId: new Uint8Array(32).fill(2) }), /credentialId/],
    ["another format", input({ challenge: CHALLENGE, fmt: "packed" }), /format/],
  ];
  for (const [label, made, reason, root] of cases) {
    await assert.rejects(verifyAttestation(await made, root ?? pki.roots), (e: unknown) => e instanceof Refusal && reason.test(e.message), label);
  }
});

test("an attestation's launch category must suit the app", async () => {
  const release = (category: number | null) => input({ challenge: CHALLENGE, launch: { category } });
  const debug = (category: number | null) => input({ challenge: CHALLENGE, bundle: DEBUG, launch: { category } });
  const preview = (category: number | null) => input({ challenge: CHALLENGE, bundle: PREVIEW, launch: { category } });
  // The release app comes from TestFlight or the App Store, as Influx
  // Preview does; the debug app is development-signed.
  for (const made of [release(2), release(4), preview(2), debug(3)]) await verifyAttestation(await made, pki.roots);
  for (const [label, made] of [
    ["release, development-signed", release(3)],
    ["preview, development-signed", preview(3)],
    ["release, category 1", release(1)],
    ["release, no category", release(null)],
    ["debug, TestFlight", debug(2)],
    ["debug, App Store", debug(4)],
  ] as const) {
    await refusedFor(made.then((i) => verifyAttestation(i, pki.roots)), /launch category/, label);
  }
  const text = await input({ challenge: CHALLENGE, launch: { raw: cbor({ apple_validation_category_01: "2", apple_bundle_version_01: "0.1.0" }) } });
  await refusedFor(verifyAttestation(text, pki.roots), /launch category/);
});

test("an attestation's bundle version must be present and not below the minimum", async () => {
  const version = (bundleVersion: string | null, minBundleVersion?: string) =>
    input({ challenge: CHALLENGE, launch: { bundleVersion }, ...(minBundleVersion === undefined ? {} : { minBundleVersion }) });
  const passes = async (made: Promise<Attestation>) => assert.equal((await verifyAttestation(await made, pki.roots)).bundleVersion !== undefined, true);
  // A build number that is a time, to the minute or the second, is a version too.
  for (const accepted of ["0.1.0", "0.1", "0.1.1", "0.2", "1.0.0", "10.0", "18", "2611162154", "261116215400"]) await passes(version(accepted));
  await refusedFor(version(null).then((i) => verifyAttestation(i, pki.roots)), /bundle version missing/);
  for (const old of ["0.0.9", "0.0", "0"]) await refusedFor(version(old).then((i) => verifyAttestation(i, pki.roots)), /too old/, old);
  for (const bad of ["", "one", "0.1.0-beta", "0..1", "v0.1", " 0.1", "2611162154000"]) {
    await refusedFor(version(bad).then((i) => verifyAttestation(i, pki.roots)), /malformed/, JSON.stringify(bad));
  }
  // Without a minimum, presence is enough.
  await passes(input({ challenge: CHALLENGE, launch: { bundleVersion: "anything" }, minBundleVersion: undefined }));
  await refusedFor(
    input({ challenge: CHALLENGE, launch: { bundleVersion: null }, minBundleVersion: undefined }).then((i) => verifyAttestation(i, pki.roots)),
    /bundle version missing/,
  );
});

test("the layouts a real Mac attestation uses are read", async () => {
  // A development-signed Mac app attests in production: the debug app may.
  await verifyAttestation(await input({ challenge: CHALLENGE, bundle: DEBUG, aaguid: AAGUID_PRODUCTION }), pki.roots);
  // A development-signed app may leave out its version; a distributed one may not.
  const debug = await verifyAttestation(await input({ challenge: CHALLENGE, bundle: DEBUG, launch: { bundleVersion: null } }), pki.roots);
  assert.deepEqual([debug.category, debug.bundleVersion], [3, undefined]);
  await refusedFor(input({ challenge: CHALLENGE, launch: { bundleVersion: null } }).then((i) => verifyAttestation(i, pki.roots)), /bundle version missing/);
  // The category as four little-endian bytes (as sent) or as the UInt32 Apple documents.
  const asInteger = await input({ challenge: CHALLENGE, launch: { raw: cbor({ apple_validation_category_01: 4, apple_bundle_version_01: "0.1.0" }) } });
  assert.equal((await verifyAttestation(asInteger, pki.roots)).category, 4);
  for (const raw of [new Uint8Array([2, 0, 0]), "2"]) {
    const odd = input({ challenge: CHALLENGE, launch: { raw: cbor({ apple_validation_category_01: raw, apple_bundle_version_01: "0.1.0" }) } });
    await refusedFor(odd.then((i) => verifyAttestation(i, pki.roots)), /launch category missing/);
  }
});

test("an attestation's extensions must be flagged and fill the rest of authData", async () => {
  const launch = (value: Launch) => input({ challenge: CHALLENGE, launch: value }).then((i) => verifyAttestation(i, pki.roots));
  await refusedFor(launch({ flag: false }), /flag not set/);
  await refusedFor(launch({ raw: new Uint8Array() }), /CBOR: truncated/);
  await refusedFor(launch({ raw: concat(cbor({ apple_validation_category_01: 2, apple_bundle_version_01: "0.1.0" }), new Uint8Array([0xf6])) }), /trailing bytes/);
  await refusedFor(launch({ raw: cbor("not a map") }), /not a map/);
});

test("registration checks the launch context and stores it", async () => {
  const { env, keys } = await attestEnv({ REQUIRE_ATTESTATION: "true" });
  const register = async (bundle: string, launch: Launch) => {
    const challenge = await newChallenge(env);
    const made = await makeAttestation(pki, { challenge, bundle, launch });
    return worker.fetch(registerRequest({ platform: "ios", appId: bundle, keyId: b64(made.keyId), attestation: b64(made.attestation), challenge }), env);
  };
  const stored = await register(RELEASE, { category: 4, bundleVersion: "0.3.1" });
  assert.equal(stored.status, 201);
  const { keyId } = (await stored.json()) as { keyId: string };
  const record = keys.storage(keyId).map.get("key") as { category: number; bundleVersion: string };
  assert.deepEqual([record.category, record.bundleVersion], [4, "0.3.1"]);
  assert.equal((await register(DEBUG, { category: 3 })).status, 201);
  assert.equal((await register(PREVIEW, { category: 2, bundleVersion: "0.3.1" })).status, 201);
  // A build it doesn't accept is refused for good: a new key won't help.
  for (const [bundle, launch] of [
    [RELEASE, { category: 3 }],
    [RELEASE, { category: 1 }],
    [DEBUG, { category: 2 }],
    [DEBUG, { category: 4 }],
    [RELEASE, { bundleVersion: "0.0.1" }],
    [RELEASE, { bundleVersion: "one" }],
    [RELEASE, { bundleVersion: "0.1.0-beta" }],
  ] as const) {
    await expectError(await register(bundle, launch), 403, "app_not_accepted");
  }
  // A missing entry or an unflagged map is malformed, not a policy.
  for (const launch of [{ category: null }, { bundleVersion: null }, { flag: false }]) {
    await expectError(await register(RELEASE, launch), 401, "attestation_invalid");
  }
  // A raised minimum applies to new registrations.
  const { env: strict } = await attestEnv({ MIN_BUNDLE_VERSION: "0.4", REQUIRE_ATTESTATION: "true" });
  const challenge = await newChallenge(strict);
  const made = await makeAttestation(pki, { challenge, launch: { bundleVersion: "0.3.9" } });
  await expectError(
    await worker.fetch(registerRequest({ platform: "ios", appId: RELEASE, keyId: b64(made.keyId), attestation: b64(made.attestation), challenge }), strict),
    403,
    "app_not_accepted",
  );
});

test("until attestation is required, a build it doesn't accept is never shut out", async () => {
  // Phase 1: the app hears that its attestation wasn't accepted, which makes
  // it ask without one, rather than app_not_accepted, which stops it asking.
  const { env } = await attestEnv();
  const challenge = await newChallenge(env);
  const made = await makeAttestation(pki, { challenge, launch: { category: 3 } });
  await expectError(
    await worker.fetch(registerRequest({ platform: "ios", appId: RELEASE, keyId: b64(made.keyId), attestation: b64(made.attestation), challenge }), env),
    401,
    "attestation_invalid",
  );
  // A genuine assertion from a build it no longer accepts is signed for, as unattested.
  const { env: open, keys } = await attestEnv();
  const key = await registered(open);
  (keys.storage(key.keyId).map.get("key") as { appId: string }).appId = "com.example.dropped";
  const response = await worker.fetch(await attestedRequest(open, { ...key, appId: `${TEAM}.com.example.dropped` }, 1), open);
  assert.equal(response.status, 200);
  const usage = (await (await worker.fetch(new Request(`${ORIGIN}/oauth/usage`), open)).json()) as { attested: number; unattested: number };
  assert.deepEqual([usage.attested, usage.unattested], [0, 1]);
});

test("a policy refusal is only given to an otherwise valid attestation", async () => {
  // A forged attestation for a build it wouldn't accept is still just invalid.
  const forged = await input({ challenge: CHALLENGE, nonce: new Uint8Array(32), launch: { category: 3 } });
  await refusedFor(verifyAttestation(forged, pki.roots), /nonce: mismatch/);
  const mac = await input({ challenge: CHALLENGE, platform: "mac", keyId: new Uint8Array(32).fill(1) });
  await refusedFor(verifyAttestation(mac, pki.roots), /keyId/);
  await assert.rejects(verifyAttestation(forged, pki.roots), (e: unknown) => e instanceof Refusal && e.kind === "invalid");
});

test("registration checks the attestation's receipt and keeps it", async () => {
  const { env, keys } = await attestEnv();
  const register = async (receipt?: unknown) => {
    const challenge = await newChallenge(env);
    const made = await makeAttestation(pki, { challenge, receipt });
    return { made, response: await worker.fetch(registerRequest({ platform: "ios", appId: RELEASE, keyId: b64(made.keyId), attestation: b64(made.attestation), challenge }), env) };
  };
  const { made, response } = await register();
  assert.equal(response.status, 201);
  const { keyId } = (await response.json()) as { keyId: string };
  const stored = Buffer.from((keys.storage(keyId).map.get("key") as { receipt: string }).receipt, "base64");
  const sent = (decodeCbor(made.attestation) as Map<string, Map<string, unknown>>).get("attStmt")?.get("receipt") as Uint8Array;
  assert.deepEqual(new Uint8Array(stored), sent);
  for (const bad of [null, new Uint8Array(), crypto.getRandomValues(new Uint8Array(600)), "a receipt", 7]) {
    await expectError((await register(bad)).response, 401, "attestation_invalid");
  }
});

test("a receipt must be Apple's, for this app and key, and fresh", async () => {
  const leaf = await certificate({ subject: "leaf", issuer: "Test App Attestation CA 1", spki: (await ecKeys("P-256")).spki, signer: pki.intermediate.privateKey });
  const appId = `${TEAM}.${RELEASE}`;
  const check = (receipt: Uint8Array, overrides: Partial<{ appId: string; credCert: Uint8Array; type: "ATTEST" | "RECEIPT" }> = {}, root = pki.receipt.rootCertificate) =>
    verifyReceipt({ receipt, appId, credCert: leaf, type: "ATTEST", ...overrides }, root);
  const made = (options: Partial<ReceiptOptions> = {}, receiptPki = pki.receipt) => makeReceipt(receiptPki, { appId, credCert: leaf, ...options });

  // Apple's BER and plain DER both read, and the fields come back.
  const fields = await check(await made());
  assert.deepEqual([fields.appId, fields.type, fields.riskMetric], [appId, "ATTEST", undefined]);
  assert.ok(fields.expires && fields.expires > Date.now());
  await check(await made({ der: true }));
  // A RECEIPT from Apple's server carries the metric and its window.
  const refreshed = await check(await made({ type: "RECEIPT", fields: { 17: "3", 19: new Date(Date.now() + 86_400_000).toISOString() } }), { type: "RECEIPT" });
  assert.equal(refreshed.riskMetric, 3);
  assert.ok(refreshed.notBefore && refreshed.notBefore > Date.now());

  const other = await makeReceiptPki();
  const unmarked = await makeReceiptPki(false);
  const cases: [string, () => Promise<ReceiptFields>, RegExp][] = [
    ["another app", () => made().then((r) => check(r, { appId: `${TEAM}.${DEBUG}` })), /receipt: app ID/],
    ["another key", () => made().then((r) => check(r, { credCert: pki.intermediateCertificate })), /receipt: key/],
    ["the other kind", () => made().then((r) => check(r, { type: "RECEIPT" })), /receipt: type/],
    ["six minutes old", () => made({ created: new Date(Date.now() - 6 * 60_000) }).then((r) => check(r)), /not fresh/],
    ["made in the future", () => made({ created: new Date(Date.now() + 5 * 60_000) }).then((r) => check(r)), /not fresh/],
    ["a signature over something else", () => made({ signedPayload: new Uint8Array([1]) }).then((r) => check(r)), /receipt: signature/],
    ["another root", () => made({}, other).then((r) => check(r)), /chain: signature/],
    ["a chain without Apple's receipt marks", () => made({}, unmarked).then((r) => check(r, {}, unmarked.rootCertificate)), /not a receipt signer/],
    ["no app ID", () => made({ fields: { 2: null } }).then((r) => check(r)), /field 2 missing/],
    ["no creation time", () => made({ fields: { 12: null } }).then((r) => check(r)), /field 12 missing/],
    ["a creation time that isn't one", () => made({ fields: { 12: "soon" } }).then((r) => check(r)), /not a date/],
    ["a metric that isn't a number", () => made({ fields: { 17: "many" } }).then((r) => check(r)), /field 17/],
    ["trailing bytes", () => made().then((r) => check(concat(r, new Uint8Array([0])))), /trailing/],
  ];
  for (const [label, result, reason] of cases) {
    await assert.rejects(result(), (e: unknown) => e instanceof Refusal && reason.test(e.message), label);
  }
  // A truncated or corrupted receipt is a refusal, never a crash.
  const good = await made();
  for (let i = 0; i < good.length; i += 7) {
    const cut = check(good.slice(0, i));
    await assert.rejects(cut, (e: unknown) => e instanceof Refusal, `cut at ${i}`);
    const flipped = good.slice();
    flipped[i] ^= 0xff;
    await check(flipped).catch((e: unknown) => assert.ok(e instanceof Refusal, `flipped at ${i}: ${e}`));
  }
});

test("the deployed Worker chains only to Apple's root", async () => {
  // No root given: Apple's embedded one, which never signed the test PKI.
  await assert.rejects(verifyAttestation(await input({ challenge: CHALLENGE })), (e: unknown) => e instanceof Refusal && /chain/.test(e.message));
  // Its root parses, and is P-384, signed with SHA-384, in date until 2045.
  const { APPLE_APP_ATTESTATION_ROOT_CA, pemToDer } = await import("../src/attest.ts");
  const der = pemToDer(APPLE_APP_ATTESTATION_ROOT_CA);
  const root = parseCertificate(der);
  assert.equal(root.signatureAlgorithm, "1.2.840.10045.4.3.3");
  assert.equal(root.publicKey.curve, "1.3.132.0.34");
  assert.equal(new Date(root.notAfter).toISOString(), "2045-03-15T00:00:00.000Z");
  assert.equal(
    Buffer.from(await sha256(der)).toString("hex").toUpperCase(),
    "1CB9823BA28BA6AD2D33A006941DE2AE4F513EF1D4E831B9F7E0FA7B6242C932",
  );
  // Receipts chain to Apple Root CA - G3: P-384, in date until 2039.
  const { APPLE_ROOTS } = await import("../src/attest.ts");
  const g3 = parseCertificate(APPLE_ROOTS.receipt);
  assert.equal(g3.publicKey.curve, "1.3.132.0.34");
  assert.equal(new Date(g3.notAfter).toISOString(), "2039-04-30T18:19:06.000Z");
  assert.equal(
    Buffer.from(await sha256(APPLE_ROOTS.receipt)).toString("hex").toUpperCase(),
    "63343ABFB89A6A03EBB57E9B3F5FA7BE7C4F5C756F3017B3A8C488C3653E9179",
  );
  // A test receipt doesn't chain to it.
  const leaf = await certificate({ subject: "leaf", issuer: "x", spki: (await ecKeys("P-256")).spki, signer: pki.intermediate.privateKey });
  const receipt = await makeReceipt(pki.receipt, { appId: `${TEAM}.${RELEASE}`, credCert: leaf });
  await assert.rejects(verifyReceipt({ receipt, appId: `${TEAM}.${RELEASE}`, credCert: leaf, type: "ATTEST" }, APPLE_ROOTS.receipt), Refusal);
});

// Attested assertion requests

test("signs for an attested caller and stores its counter", async () => {
  const { env, keys, counts } = await attestEnv();
  for (const platform of ["ios", "mac"] as const) {
    const key = await registered(env, platform);
    const response = await worker.fetch(await attestedRequest(env, key, 1), env);
    assert.equal(response.status, 200, platform);
    assert.ok(((await response.json()) as { client_assertion: string }).client_assertion);
    const record = keys.storage(key.keyId).map.get("key") as { counter: number; category: number; bundleVersion: string };
    assert.equal(record.counter, 1);
    assert.equal(record.category, 2);
    assert.equal(record.bundleVersion, "0.1.0");
    // A newer build's assertion notes its version and category.
    assert.equal((await worker.fetch(await attestedRequest(env, key, 5, {}, { category: 4, bundleVersion: "0.2.0" }), env)).status, 200);
    const later = keys.storage(key.keyId).map.get("key") as { counter: number; category: number; bundleVersion: string };
    assert.deepEqual([later.counter, later.category, later.bundleVersion], [5, 4, "0.2.0"]);
  }
  assert.equal(counts.storage("assertions").map.get(`${new Date().toISOString().slice(0, 10)} attested`), 4);
});

test("refuses a replayed or older assertion", async () => {
  const { env } = await attestEnv();
  const key = await registered(env);
  const first = await attestedRequest(env, key, 3);
  const replay = first.clone();
  assert.equal((await worker.fetch(first, env)).status, 200);
  await expectError(await worker.fetch(replay, env), 401, "attestation_required");
  await expectError(await worker.fetch(await attestedRequest(env, key, 3), env), 401, "attestation_required");
  await expectError(await worker.fetch(await attestedRequest(env, key, 2), env), 401, "attestation_required");
  assert.equal((await worker.fetch(await attestedRequest(env, key, 4), env)).status, 200);
});

test("the same attested request sent twice at once is signed once", async () => {
  const { env, keys } = await attestEnv();
  const key = await registered(env);
  const request = await attestedRequest(env, key, 1);
  const statuses = (await Promise.all([worker.fetch(request.clone(), env), worker.fetch(request, env)])).map((r) => r.status).sort();
  assert.deepEqual(statuses, [200, 401]);
  // Two assertions racing on one key: however they land, the counter ends at the higher.
  const [low, high] = [await attestedRequest(env, key, 2), await attestedRequest(env, key, 3)];
  await Promise.all([worker.fetch(high, env), worker.fetch(low, env)]);
  assert.equal((keys.storage(key.keyId).map.get("key") as { counter: number }).counter, 3);
});

test("an attested request needs a challenge it issued, unused and in date", async () => {
  const { env, challenges } = await attestEnv();
  const key = await registered(env);
  let counter = 1;
  const refused = async (fields: Record<string, unknown>) =>
    expectError(await worker.fetch(await attestedRequest(env, key, counter++, fields), env), 401, "attestation_required");
  await refused({ challenge: undefined });
  await refused({ challenge: 42 });
  await refused({ challenge: "short" });
  await refused({ challenge: CHALLENGE });

  const expired = await newChallenge(env);
  challenges.storage("challenges").map.set(expired, Date.now() - 1);
  await refused({ challenge: expired });

  // One challenge serves one assertion, even with a higher counter.
  const once = await newChallenge(env);
  assert.equal((await worker.fetch(await attestedRequest(env, key, counter++, { challenge: once }), env)).status, 200);
  await refused({ challenge: once });

  // A registration's challenge is spent by the registration.
  const registration = await newChallenge(env);
  const made = await makeAttestation(pki, { challenge: registration });
  const body = { platform: "ios", appId: RELEASE, keyId: b64(made.keyId), attestation: b64(made.attestation), challenge: registration };
  assert.equal((await worker.fetch(registerRequest(body), env)).status, 201);
  await refused({ challenge: registration });

  // A refused request's counter wasn't spent, so the next good one still passes.
  assert.equal((await worker.fetch(await attestedRequest(env, key, counter++), env)).status, 200);
});

test("a forged assertion doesn't spend the challenge it names", async () => {
  const { env, challenges } = await attestEnv();
  const key = await registered(env);
  const challenge = await newChallenge(env);
  const forged = await attestedRequest(env, { ...key, leaf: await ecKeys("P-256") }, 1, { challenge });
  await expectError(await worker.fetch(forged, env), 401, "attestation_required");
  assert.ok(challenges.storage("challenges").map.has(challenge));
  assert.equal((await worker.fetch(await attestedRequest(env, key, 1, { challenge }), env)).status, 200);
});

test("an unattested request needs no challenge while attestation is optional", async () => {
  const { env } = await attestEnv();
  assert.equal((await worker.fetch(plainRequest(), env)).status, 200);
});

test("an unknown key and a key idle for 90 days answer key_unknown", async () => {
  const { env, keys, challenges } = await attestEnv();
  const key = await registered(env);
  const stranger = { ...key, keyId: b64(new Uint8Array(32).fill(4)) };
  const challenge = await newChallenge(env);
  await expectError(await worker.fetch(await attestedRequest(env, stranger, 1, { challenge }), env), 401, "key_unknown");
  // Its challenge is left for the request after it registers.
  assert.ok(challenges.storage("challenges").map.has(challenge));

  const record = keys.storage(key.keyId).map.get("key") as { lastUsed: number };
  record.lastUsed = Date.now() - KEY_IDLE_LIMIT_MS - 1000;
  await expectError(await worker.fetch(await attestedRequest(env, key, 1), env), 401, "key_unknown");
  assert.equal(keys.storage(key.keyId).map.has("key"), false);
  // Once forgotten, it stays unknown until the install registers again.
  await expectError(await worker.fetch(await attestedRequest(env, key, 2), env), 401, "key_unknown");
});

test("every other attestation failure on a known key answers attestation_required", async () => {
  const { env } = await attestEnv();
  const key = await registered(env);
  // A bad signature: another install's key signing for this key ID.
  await expectError(await worker.fetch(await attestedRequest(env, { ...key, leaf: await ecKeys("P-256") }, 1), env), 401, "attestation_required");
  assert.equal((await worker.fetch(await attestedRequest(env, key, 5), env)).status, 200);
  // A counter that didn't rise.
  await expectError(await worker.fetch(await attestedRequest(env, key, 5), env), 401, "attestation_required");
  // A spent challenge.
  const spent = await newChallenge(env);
  assert.equal((await worker.fetch(await attestedRequest(env, key, 6, { challenge: spent }), env)).status, 200);
  await expectError(await worker.fetch(await attestedRequest(env, key, 7, { challenge: spent }), env), 401, "attestation_required");
  // A key header that isn't a key ID at all is malformed, not unknown.
  const malformed = await attestedRequest(env, key, 8);
  malformed.headers.set("X-Influx-Key", b64(new Uint8Array(16)));
  await expectError(await worker.fetch(malformed, env), 401, "attestation_required");
});

test("an assertion only covers the exact body and app it was made for", async () => {
  const { env } = await attestEnv();
  const key = await registered(env);
  const signed = await attestedRequest(env, key, 1);
  const tampered = new Request(signed.url, {
    method: "POST",
    headers: signed.headers,
    body: JSON.stringify({ aud: "https://bsky.social", challenge: await newChallenge(env), kid: "key-1" }),
  });
  await expectError(await worker.fetch(tampered, env), 401, "attestation_required");
  await expectError(await worker.fetch(await attestedRequest(env, { ...key, appId: `${TEAM}.${DEBUG}` }, 1), env), 401, "attestation_required");
  // A key made by another install can't sign for this key ID.
  const other = await ecKeys("P-256");
  await expectError(await worker.fetch(await attestedRequest(env, { ...key, leaf: other }, 1), env), 401, "attestation_required");
});

test("an assertion's launch category and bundle version are checked like a registration's", async () => {
  const { env, challenges } = await attestEnv({ REQUIRE_ATTESTATION: "true" });
  const key = await registered(env);
  let counter = 1;
  const send = async (launch: Launch, challenge?: string) =>
    worker.fetch(await attestedRequest(env, key, counter++, challenge ? { challenge } : {}, launch), env);
  // A build it doesn't accept: 403, and its challenge is left unspent.
  for (const launch of [{ category: 3 }, { category: 1 }, { bundleVersion: "0.0.9" }, { bundleVersion: "one" }, { bundleVersion: "0.1.0-beta" }]) {
    const challenge = await newChallenge(env);
    await expectError(await send(launch, challenge), 403, "app_not_accepted");
    assert.ok(challenges.storage("challenges").map.has(challenge), JSON.stringify(launch));
  }
  // Malformed extensions stay 401.
  for (const launch of [{ category: null }, { bundleVersion: null }, { flag: false }]) {
    await expectError(await send(launch), 401, "attestation_required");
  }
  for (const launch of [{ category: 2 }, { category: 4 }, { bundleVersion: "0.1.0" }, { bundleVersion: "1.0" }]) {
    assert.equal((await send(launch)).status, 200, JSON.stringify(launch));
  }
  // The debug app's keys assert as development-signed builds.
  const debug = await registered(env, "ios", DEBUG);
  assert.equal((await worker.fetch(await attestedRequest(env, debug, 1, {}, { category: 3 }), env)).status, 200);
  await expectError(await worker.fetch(await attestedRequest(env, debug, 2, {}, { category: 2 }), env), 403, "app_not_accepted");
  // A raised minimum refuses keys registered under the old one.
  const raised = { ...env, MIN_BUNDLE_VERSION: "0.2" };
  await expectError(await worker.fetch(await attestedRequest(raised, key, counter++), raised), 403, "app_not_accepted");
});

test("an assertion for an app no longer accepted answers app_not_accepted, but only when genuine", async () => {
  const { env, keys } = await attestEnv({ REQUIRE_ATTESTATION: "true" });
  const key = await registered(env);
  (keys.storage(key.keyId).map.get("key") as { appId: string }).appId = "com.example.dropped";
  const signedFor = { ...key, appId: `${TEAM}.com.example.dropped` };
  await expectError(await worker.fetch(await attestedRequest(env, signedFor, 1), env), 403, "app_not_accepted");
  // A forged assertion for the same key is just invalid.
  await expectError(await worker.fetch(await attestedRequest(env, { ...signedFor, leaf: await ecKeys("P-256") }, 2), env), 401, "attestation_required");
  // The genuine one is counted by where it came from, like an unattested request.
  const { events } = (await (await worker.fetch(new Request(`${ORIGIN}/oauth/usage`), env)).json()) as { events: Record<string, number> };
  assert.equal(events["unattested: other"], 1);
});

test("one attestation header without the other is refused", async () => {
  const { env } = await attestEnv();
  const key = await registered(env);
  for (const drop of ["X-Influx-Key", "X-Influx-Assertion"]) {
    const request = await attestedRequest(env, key, 1);
    request.headers.delete(drop);
    await expectError(await worker.fetch(request, env), 401, "attestation_required");
  }
});

test("REQUIRE_ATTESTATION decides whether an unattested caller is signed for", async () => {
  const { env } = await attestEnv({ REQUIRE_ATTESTATION: "true" });
  await expectError(await worker.fetch(plainRequest(), env), 401, "attestation_required");
  assert.equal((await worker.fetch(await attestedRequest(env, await registered(env), 1), env)).status, 200);
  for (const value of ["false", "", undefined]) {
    const { env: open } = await attestEnv({ REQUIRE_ATTESTATION: value });
    assert.equal((await worker.fetch(plainRequest(), open)).status, 200, String(value));
  }
});

test("usage counts attested and unattested assertions for the day", async () => {
  const { env } = await attestEnv();
  const key = await registered(env);
  await worker.fetch(plainRequest(), env);
  await worker.fetch(plainRequest(), env);
  await worker.fetch(await attestedRequest(env, key, 1), env);
  // Refused requests count as neither.
  await worker.fetch(await attestedRequest(env, key, 1), env);
  const usage = await (await worker.fetch(new Request(`${ORIGIN}/oauth/usage`), env)).json();
  assert.deepEqual(usage, {
    day: new Date().toISOString().slice(0, 10),
    count: 3,
    limit: 2000,
    attested: 1,
    unattested: 2,
    // The refused request is counted by the check that failed.
    events: { challenge: 3, "register ios: ok": 1, "unattested: other": 2, "assertion: counter: not increasing": 1 },
  });
});

// Apple's fraud metric

test("registration reads Apple's fraud metric when the Worker has a key, and never fails on it", async () => {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  // Assembled, so no key-shaped text is committed for secret scanners to flag.
  const label = ["PRIVATE", "KEY"].join(" ");
  const pem = (body: string) => `-----BEGIN ${label}-----\n${body}\n-----END ${label}-----\n`;
  const p8 = pem(b64(pkcs8));
  const calls: { url: string; authorization: string; body: string }[] = [];
  let answer: (leaf: Uint8Array, appId: string) => Promise<Response> = async () => new Response("", { status: 500 });
  let leaf = new Uint8Array();
  let appId = "";
  const apple: typeof fetch = async (url, init) => {
    calls.push({ url: String(url), authorization: String((init?.headers as Record<string, string>).Authorization), body: String(init?.body) });
    return answer(leaf, appId);
  };
  const metricWorker = createWorker({ roots: pki.roots, appleFetch: apple });
  const register = async (env: Env, bundle = RELEASE) => {
    const challenge = await newChallenge(env);
    const made = await makeAttestation(pki, { challenge, bundle });
    const statement = (decodeCbor(made.attestation) as Map<string, Map<string, unknown>>).get("attStmt");
    leaf = (statement?.get("x5c") as Uint8Array[])[0];
    appId = `${TEAM}.${bundle}`;
    const response = await metricWorker.fetch(registerRequest({ platform: "ios", appId: bundle, keyId: b64(made.keyId), attestation: b64(made.attestation), challenge }), env);
    assert.equal(response.status, 201);
    const { keyId } = (await response.json()) as { keyId: string };
    return { keyId, sent: statement?.get("receipt") as Uint8Array };
  };
  const usageEvents = async (env: Env) =>
    ((await (await metricWorker.fetch(new Request(`${ORIGIN}/oauth/usage`), env)).json()) as { events: Record<string, number> }).events;
  const key = JSON.stringify({ keyId: "ABCDE12345", teamId: TEAM, p8 });

  // Apple answers with a RECEIPT carrying the metric, which replaces the attestation's.
  const { env, keys } = await attestEnv({ APP_ATTEST_KEY: key });
  let returned = new Uint8Array();
  answer = async (credCert, forApp) => {
    returned = await makeReceipt(pki.receipt, { appId: forApp, credCert, type: "RECEIPT", fields: { 17: "2", 19: new Date(Date.now() + 86_400_000).toISOString() } });
    return new Response(b64(returned), { status: 200 });
  };
  const { keyId, sent } = await register(env);
  const record = keys.storage(keyId).map.get("key") as { riskMetric?: number; receipt: string; credCert: string };
  assert.equal(record.riskMetric, 2);
  assert.equal(record.receipt, b64(returned));
  // The key's certificate is kept, for refreshing the metric later.
  assert.equal(record.credCert, b64(leaf));
  // It asked the production service, with the attestation's receipt and an
  // APNs-style provider token from the configured key.
  assert.equal(calls[0].url, "https://data.appattest.apple.com/v1/attestationData");
  assert.equal(calls[0].body, b64(sent));
  const [header, payload, signature] = calls[0].authorization.split(".");
  const decode = (part: string) => JSON.parse(Buffer.from(part, "base64url").toString());
  assert.deepEqual(decode(header), { alg: "ES256", kid: "ABCDE12345" });
  assert.equal(decode(payload).iss, TEAM);
  assert.ok(Math.abs(decode(payload).iat - Date.now() / 1000) < 60);
  assert.ok(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, pair.publicKey, Buffer.from(signature, "base64url"), enc.encode(`${header}.${payload}`)));
  // A key attested in development goes to the development service.
  const { env: debugEnv } = await attestEnv({ APP_ATTEST_KEY: key });
  await register(debugEnv, DEBUG);
  assert.equal(calls[1].url, "https://data-development.appattest.apple.com/v1/attestationData");

  // Anything going wrong registers the key anyway, keeping the attestation's receipt.
  const failures: [string, (credCert: Uint8Array, forApp: string) => Promise<Response>, string][] = [
    ["Apple refuses", async () => new Response("Unauthorized", { status: 401 }), "metric: Apple 401"],
    ["Apple is unreachable", async () => Promise.reject(new TypeError("network")), "metric: unreachable or malformed"],
    ["an answer that isn't a receipt", async () => new Response(b64(new Uint8Array([1, 2, 3])), { status: 200 }), "metric: BER: truncated"],
    [
      "a receipt for another key",
      async (_credCert, forApp) => new Response(b64(await makeReceipt(pki.receipt, { appId: forApp, credCert: pki.intermediateCertificate, type: "RECEIPT" })), { status: 200 }),
      "metric: receipt: key",
    ],
  ];
  for (const [label, failure, event] of failures) {
    const { env: failing, keys: failingKeys } = await attestEnv({ APP_ATTEST_KEY: key });
    answer = failure;
    const { keyId: failed, sent: original } = await register(failing);
    const kept = failingKeys.storage(failed).map.get("key") as { riskMetric?: number; receipt: string };
    assert.deepEqual([kept.riskMetric, kept.receipt], [undefined, b64(original)], label);
    assert.equal((await usageEvents(failing))[event], 1, `${label}: ${JSON.stringify(await usageEvents(failing))}`);
  }

  // A malformed key asks Apple nothing; no key at all, nothing either.
  const before = calls.length;
  const { env: unusable } = await attestEnv({ APP_ATTEST_KEY: JSON.stringify({ keyId: "ABCDE12345", teamId: TEAM, p8: pem("AAAA") }) });
  await register(unusable);
  assert.equal((await usageEvents(unusable))["metric: key unusable"], 1);
  const { env: malformed } = await attestEnv({ APP_ATTEST_KEY: JSON.stringify({ keyId: "short", teamId: TEAM, p8 }) });
  await register(malformed);
  assert.equal((await usageEvents(malformed))["metric: key malformed"], 1);
  const { env: none } = await attestEnv();
  await register(none);
  assert.equal(calls.length, before);
  assert.equal(Object.keys(await usageEvents(none)).some((name) => name.startsWith("metric")), false);
});

test("a key registered before the Worker had an App Attest key catches up on its metric", async () => {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const label = ["PRIVATE", "KEY"].join(" ");
  const p8 = `-----BEGIN ${label}-----\n${b64(new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey)))}\n-----END ${label}-----\n`;
  let calls = 0;
  // Apple answers for whatever key and app the receipt it is sent names.
  const apple: typeof fetch = async (_url, init) => {
    calls++;
    const sent = storedReceiptFields(new Uint8Array(Buffer.from(String(init?.body), "base64")));
    return new Response(b64(await makeReceipt(pki.receipt, { appId: sent.appId, credCert: sent.credCert, type: "RECEIPT", fields: { 17: "4" } })), { status: 200 });
  };
  const metricWorker = createWorker({ roots: pki.roots, appleFetch: apple });
  const record = (keys: Awaited<ReturnType<typeof attestEnv>>["keys"], keyId: string) =>
    keys.storage(keyId).map.get("key") as { riskMetric?: number; metricCheckedAt?: number; credCert?: string; environment?: string };

  // Registered with no key configured, and from before certificates were kept.
  const { env, keys } = await attestEnv();
  const key = await registered(env);
  delete record(keys, key.keyId).credCert;
  delete record(keys, key.keyId).environment;
  env.APP_ATTEST_KEY = JSON.stringify({ keyId: "ABCDE12345", teamId: TEAM, p8 });
  // Its next attested request reads the metric, from its stored receipt.
  assert.equal((await metricWorker.fetch(await attestedRequest(env, key, 1), env)).status, 200);
  assert.equal(calls, 1);
  assert.equal(record(keys, key.keyId).riskMetric, 4);
  // Once it has one, it asks no more.
  assert.equal((await metricWorker.fetch(await attestedRequest(env, key, 2), env)).status, 200);
  assert.equal(calls, 1);

  // A failed catch-up waits a day before asking again, and never fails the request.
  const { env: failing, keys: failingKeys } = await attestEnv();
  const other = await registered(failing);
  failing.APP_ATTEST_KEY = JSON.stringify({ keyId: "ABCDE12345", teamId: TEAM, p8 });
  const refusing = createWorker({ roots: pki.roots, appleFetch: async () => (calls++, new Response("", { status: 503 })) });
  assert.equal((await refusing.fetch(await attestedRequest(failing, other, 1), failing)).status, 200);
  assert.equal((await refusing.fetch(await attestedRequest(failing, other, 2), failing)).status, 200);
  assert.equal(calls, 2);
  assert.ok(record(failingKeys, other.keyId).metricCheckedAt);
  assert.equal(record(failingKeys, other.keyId).riskMetric, undefined);
  record(failingKeys, other.keyId).metricCheckedAt = Date.now() - 25 * 60 * 60 * 1000;
  assert.equal((await metricWorker.fetch(await attestedRequest(failing, other, 3), failing)).status, 200);
  assert.equal(record(failingKeys, other.keyId).riskMetric, 4);

  // "off", the deploy's word for a removed key, asks nothing; nor does another team's key.
  for (const [value, event] of [["off", undefined], [JSON.stringify({ keyId: "ABCDE12345", teamId: "OTHERTEAM1", p8 }), "metric: key for another team"]] as const) {
    const { env: quiet } = await attestEnv({ APP_ATTEST_KEY: value });
    const before = calls;
    const challenge = await newChallenge(quiet);
    const made = await makeAttestation(pki, { challenge });
    const response = await metricWorker.fetch(registerRequest({ platform: "ios", appId: RELEASE, keyId: b64(made.keyId), attestation: b64(made.attestation), challenge }), quiet);
    assert.equal(response.status, 201);
    assert.equal(calls, before, value);
    const { events } = (await (await metricWorker.fetch(new Request(`${ORIGIN}/oauth/usage`), quiet)).json()) as { events: Record<string, number> };
    assert.deepEqual(Object.keys(events).filter((name) => name.startsWith("metric")), event ? [event] : [], value);
  }
});

test("usage counts each registration refusal by platform and check, and an unknown key", async () => {
  const { env } = await attestEnv();
  const challenge = await newChallenge(env);
  const made = await makeAttestation(pki, { challenge });
  // A Mac key without the access policy, then the spent challenge again.
  await worker.fetch(registerRequest({ platform: "mac", appId: RELEASE, keyId: b64(made.keyId), attestation: b64(made.attestation), challenge }), env);
  await worker.fetch(registerRequest({ platform: "ios", appId: RELEASE, keyId: b64(made.keyId), attestation: b64(made.attestation), challenge }), env);
  await worker.fetch(registerRequest({ platform: "ios", appId: "com.example.other", keyId: b64(made.keyId), attestation: b64(made.attestation), challenge }), env);
  await worker.fetch(await attestedRequest(env, { keyId: b64(new Uint8Array(32)), leaf: made.leaf, appId: `${TEAM}.${RELEASE}` }, 1), env);
  const { events } = (await (await worker.fetch(new Request(`${ORIGIN}/oauth/usage`), env)).json()) as { events: Record<string, number> };
  assert.deepEqual(events, {
    challenge: 2,
    "register mac: aclBlob: missing": 1,
    "register ios: bad challenge": 1,
    "register ios: app ID not attested": 1,
    "assertion: key unknown": 1,
  });
});

// Malformed input

test("malformed base64, CBOR and DER are refusals, never crashes", async () => {
  const { env } = await attestEnv();
  const bad = async (fields: Record<string, string>) => {
    const challenge = await newChallenge(env);
    const made = await makeAttestation(pki, { challenge });
    return worker.fetch(registerRequest({ platform: "ios", appId: RELEASE, keyId: b64(made.keyId), attestation: b64(made.attestation), challenge, ...fields }), env);
  };
  const x5cGarbage = cbor({ fmt: "apple-appattest", attStmt: { x5c: [new Uint8Array([0x30, 0x82, 0xff]), new Uint8Array([1])] }, authData: new Uint8Array(60) });
  for (const fields of [
    { attestation: "!!!" },
    { attestation: b64(new Uint8Array([0xbf, 0xff])) },
    { attestation: b64(new Uint8Array([0xa1, 0x63])) },
    { attestation: b64(cbor([1, 2, 3])) },
    { attestation: b64(x5cGarbage) },
    { keyId: "not base64!" },
    { keyId: b64(new Uint8Array(31)) },
  ]) {
    await expectError(await bad(fields), 401, "attestation_invalid");
  }
  const key = await registered(env);
  for (const assertion of ["***", b64(new Uint8Array([0x9f])), b64(cbor({ signature: new Uint8Array([0x30, 0x01]), authenticatorData: new Uint8Array(37) })), b64(cbor({ signature: new Uint8Array(3) }))]) {
    const request = await attestedRequest(env, key, 1);
    request.headers.set("X-Influx-Assertion", assertion);
    await expectError(await worker.fetch(request, env), 401, "attestation_required");
  }
  const request = await attestedRequest(env, key, 1);
  request.headers.set("X-Influx-Key", "%%%");
  await expectError(await worker.fetch(request, env), 401, "attestation_required");
});

test("every corrupted byte of an attestation is refused or harmless", async () => {
  const valid = await input({ challenge: CHALLENGE });
  for (let i = 0; i < valid.attestation.length; i += 7) {
    const attestation = valid.attestation.slice();
    attestation[i] ^= 0x5a;
    try {
      await verifyAttestation({ ...valid, attestation }, pki.roots);
    } catch (e) {
      assert.ok(e instanceof Refusal, `byte ${i}: ${e}`);
    }
  }
  for (let length = 0; length < valid.attestation.length; length += 13) {
    await assert.rejects(verifyAttestation({ ...valid, attestation: valid.attestation.slice(0, length) }, pki.roots), Refusal);
  }
});

test("the CBOR decoder reads App Attest's types and refuses the rest", () => {
  const value = decodeCbor(cbor({ a: [1, -2, "x", new Uint8Array([7]), true, false, null], b: 70000 })) as Map<string, unknown>;
  assert.deepEqual(value.get("a"), [1, -2, "x", new Uint8Array([7]), true, false, null]);
  assert.equal(value.get("b"), 70000);
  const refused = [
    [0x9f, 0xff], // indefinite array
    [0x5f, 0x41, 0x00, 0xff], // indefinite bytes
    [0xc0, 0x00], // a tag
    [0xf9, 0x3c, 0x00], // a half float
    [0xf7], // undefined
    [0x1c], // reserved length
    [0x01, 0x02], // trailing byte
    [0x42, 0x01], // truncated bytes
    [0x9a, 0xff, 0xff, 0xff, 0xff], // a count longer than the input
    [0xa2, 0x61, 0x61, 0x01, 0x61, 0x61, 0x02], // a duplicate key
    [0xa1, 0x41, 0x00, 0x01], // a byte-string key
    [0x62, 0xff, 0xfe], // invalid UTF-8
    [0x1b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff], // past 2^53
    [],
  ];
  for (const bytes of refused) assert.throws(() => decodeCbor(new Uint8Array(bytes)), Refusal, JSON.stringify(bytes));
  let deep = new Uint8Array([0x00]);
  for (let i = 0; i < 20; i++) deep = new Uint8Array([0x81, ...deep]);
  assert.throws(() => decodeCbor(deep), Refusal);
});

test("the DER reader refuses what DER forbids", async () => {
  const refused = [
    [0x30, 0x80, 0x00, 0x00], // indefinite length
    [0x30, 0x81, 0x05, 0, 0, 0, 0, 0], // non-minimal length
    [0x30, 0x05, 0x00], // truncated
    [0x1f, 0x01, 0x00], // a multi-byte tag
    [0x30],
  ];
  for (const bytes of refused) assert.throws(() => readElement(new Uint8Array(bytes)), Refusal, JSON.stringify(bytes));
  assert.throws(() => parseCertificate(new Uint8Array([0x30, 0x00])), Refusal);
  assert.throws(() => parseCertificate(pki.rootCertificate.slice(0, 100)), Refusal);
  assert.throws(() => ecdsaSignatureToRaw(new Uint8Array([0x30, 0x03, 0x02, 0x01, 0x01]), 32), Refusal);
  assert.throws(() => ecdsaSignatureToRaw(new Uint8Array([0x30, 0x06, 0x02, 0x01, 0x81, 0x02, 0x01, 0x01]), 32), Refusal);
});

test("verifyAssertion checks the signature over the nonce, the App ID and the extensions", async () => {
  const leaf = await ecKeys("P-256");
  const body = enc.encode("{}");
  const check = (assertion: Uint8Array, overrides: Partial<Parameters<typeof verifyAssertion>[0]> = {}) =>
    verifyAssertion({ assertion, clientData: body, publicKey: leaf.point, appId: `${TEAM}.${RELEASE}`, environment: "production", minBundleVersion: "0.1.0", ...overrides });
  const assertion = await makeAssertion(leaf, body, 9);
  assert.deepEqual(await check(assertion), { counter: 9, category: 2, bundleVersion: "0.1.0" });
  await refusedFor(check(assertion, { clientData: enc.encode("{ }") }), /signature/);
  await refusedFor(check(assertion, { appId: `${TEAM}.${DEBUG}` }), /rpIdHash/);
  await refusedFor(check(assertion, { publicKey: new Uint8Array(65) }), /unexpected|signature/);
  await refusedFor(check(assertion, { environment: "development" }), /launch category/);
  await refusedFor(check(assertion, { minBundleVersion: "0.1.1" }), /too old/);
  const extensionsOf = async (launch: Launch) => check(await makeAssertion(leaf, body, 9, `${TEAM}.${RELEASE}`, launch));
  await refusedFor(extensionsOf({ flag: false }), /flag not set/);
  await refusedFor(extensionsOf({ raw: new Uint8Array() }), /CBOR: truncated/);
  await refusedFor(extensionsOf({ raw: concat(cbor({ apple_validation_category_01: 2, apple_bundle_version_01: "0.1.0" }), new Uint8Array([0])) }), /trailing bytes/);
  await refusedFor(extensionsOf({ raw: cbor([2, "0.1.0"]) }), /not a map/);
});
