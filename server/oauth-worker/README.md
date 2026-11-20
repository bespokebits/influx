# The OAuth Worker: flux.bespokebits.dev and influx.bespokebits.dev

One Cloudflare Worker serving what Bluesky sign-in needs, all over HTTPS with no redirects. It is deployed with wrangler on the bespokebits.dev zone, as two custom domains, `flux.bespokebits.dev` (the one the app uses today) and `influx.bespokebits.dev` (the one it moves to with the new bundle IDs). Each host is its own OAuth client, with its own client metadata, callback and assertion `iss`, and both use the same signing key and JWKS.

The hosts are `HOSTS` in `src/index.ts` and the `routes` in `wrangler.toml`; keep the two lists the same. Every request reaches the Worker first (`run_worker_first`), and a request for any other host, workers.dev and preview URLs included, gets 421 `{"error": "unknown_host"}` before any file is served.

| Path | What | From |
| --- | --- | --- |
| `/oauth/client-metadata.json` | The client metadata for the host asked. Its `client_id` is this URL, and its `redirect_uris` and `jwks_uri` are on the same host. | the Worker (`clientMetadata`) |
| `/oauth/jwks.json` | The signing key's public half. | the Worker |
| `/oauth/callback` | Universal link target. The app catches it, so the page is only seen without the app. | `public/oauth/callback.html` |
| `POST /oauth/assertion` | The signing service, below. | the Worker |
| `POST /oauth/challenge` | A single-use App Attest challenge, below. | the Worker |
| `POST /oauth/register` | Registers an install's App Attest key, below. | the Worker |
| `GET /oauth/usage` | `{"day", "count", "limit", "attested", "unattested", "events"}`: today's assertions against the daily limit (UTC), for a volume alert, and how many of them came from attested callers. `events` counts the day's challenges, registrations by platform, refused registrations and assertions by the check that failed, attested requests by the app and platform their key was registered for (`attested: Influx Preview ios`), unattested requests by source (the app, the deploy check, or other) and, for the app, its platform (`X-Influx-Platform`) and the reason it gave (`X-Influx-Unattested`: the step that failed and DeviceCheck's error code, `reassert-…` when a replacement key failed too), and each field report's outcome (`report: stored`, `report: invalid`, `report: not attested`…), so a rollout shows whether installs attest and reports arrive. Reading it counts nothing. | the Worker |
| `POST /perf/report` | Stores one field performance report from an attested TestFlight install, below. | the Worker |
| `GET /perf/reports?days=N` | `{"days", "reports", "summaries"}`: the last N UTC days' reports (1 to 90, default 30), newest first, and a summary per platform and build, below. Reports hold nothing about who sent them; reading them counts nothing. | the Worker |
| `/.well-known/apple-app-site-association` | The app IDs allowed to take the callback, for the release, Preview, dev and UI-test bundle IDs under both app names (`dev.bespokebits.influx…` since the rename, `dev.bespokebits.flux…` until no installed build uses it), the same file on both hosts, served as `application/json` (by the `public/_headers` rule and by the Worker). It uses the current signing team, KV99MN4F58; regenerate it from `apple-app-site-association.template.json` when the Bespoke Bits team arrives. List a new app ID at least a day before its first build is installed, below. | `public/.well-known/` |

## Adding an app to the site-association file

A device does not read the file from this Worker. It asks Apple's cache (`https://app-site-association.cdn-apple.com/a/v1/<host>`), which keeps its copy for up to six hours. The device asks when the app is installed or updated, and after that about once a week. An app that the list did not name at that moment can't take the callback, so its Bluesky sign-in window can't open ("The sign-in window couldn't open"), and it stays that way until the device asks again.

So add the app ID to the file and the template, deploy, and wait a day before the first build of that app is installed. Check that Apple's cache names it first:

```sh
curl -s https://app-site-association.cdn-apple.com/a/v1/influx.bespokebits.dev | grep <bundle ID>
```

If a build was installed too soon, send an update of that app once the cache names it. Installing the update makes the device ask again.

## Configuration

- `SIGNING_KEY_JWK` (secret): the private P-256 JWK, provided by the deploy environment. Never in this repository.
- `APP_ATTEST_KEY` (secret, optional): an Apple DeviceCheck key as JSON `{"keyId", "teamId", "p8"}`, provided by the deploy environment. Its team must be `APPLE_TEAM_ID`. With it, each registration exchanges the attestation's receipt with Apple for one carrying the device's fraud metric (ADR 0033). A key registered before the secret was set, or whose exchange failed, catches up on one of its attested requests, at most once a day. Without the secret the deploy sets it to `off`, so removing it takes effect, and Apple is asked nothing.
- `SIGNING_KID` (var in `wrangler.toml`): its key ID.
- `ALLOWED_ISSUERS` (var): the authorization server issuers it signs for, separated by spaces. It starts as `https://bsky.social`, the issuer for every Bluesky-hosted account. Any other `aud` gets 400 `issuer_not_allowed`.
- `DAILY_LIMIT` (var): assertions per UTC day across all callers, 2,000 to start. Past it, requests get 503 `daily_limit` until midnight UTC. The count lives in the `DailyCount` Durable Object (SQLite-backed, so it works on the Free plan).
- `RATE_LIMITER`: the Workers rate-limit binding, 30 a minute per `CF-Connecting-IP`, shared by the assertion, challenge, register and both performance routes.
- `PERF_REPORTS`: the `PerfReports` Durable Object (SQLite-backed, migration `v3`), one for the Worker, holding the field performance reports (below).
- `APPLE_TEAM_ID` (var): the team whose App IDs (`<team>.<bundle ID>`) attested keys must name, `KV99MN4F58`. Without it, `/oauth/challenge` and `/oauth/register` answer 503 `not_configured`.
- `REQUIRE_ATTESTATION` (var): `"true"` refuses assertion requests that carry no App Attest headers. It is `"true"` since 2026-11-14 (phase 2 of ADR 0033). Set to `"false"` (phase 1), attestation is checked whenever it is sent and unattested callers are still signed for; that is the way back if real installs start failing.
- `MIN_BUNDLE_VERSION` (var): the lowest app bundle version (`CFBundleVersion`, dotted numbers such as `0.1.0`) it attests, in registrations and in every assertion, `0.1.0` to start. Versions compare number by number, missing parts counting as 0, so `0.1` equals `0.1.0`; a version that isn't dotted numbers is refused. Unset, any version is accepted as long as one is present. A malformed value refuses every attested request, so check it when raising it.
- `CHALLENGES` and `ATTESTED_KEYS`: the `Challenges` and `AttestedKey` Durable Objects (SQLite-backed, migration `v2`). There is one `Challenges` object, and one `AttestedKey` object per key, named by its key ID. An object can start another request at any await that isn't a storage call, so each reads its request body first and does its read-compare-write inside `blockConcurrencyWhile` (`src/objects.ts`): a challenge is consumed once, a counter is accepted once and never moves back, and the daily count never skips. `test/objects.test.ts` races requests against a stand-in storage that yields on every call.

There are no attestation secrets: App Attest needs only Apple's public root, which is in `src/attest.ts`.

The allowlist and the daily limit stand in for caller authentication until attestation is required. Once it is, the limit can rise.

Until the key and its ID are both set, `/oauth/assertion` and `/oauth/jwks.json` answer 503 `{"error": "not_configured"}`.

## Tests

`npm test` (Node 22 or later, no packages). The attestation tests (`test/attest.test.ts`) build a stand-in App Attest PKI with WebCrypto (`test/helpers.ts`) and never call Apple. `scripts/smoke.mjs <kid>` checks a deployed host end to end: the client metadata, the JWKS and a signed assertion, or, once `REQUIRE_ATTESTATION` is `"true"` in `wrangler.toml`, that an unattested request is refused. It names itself in its User-Agent, so `/oauth/usage` counts it as the deploy check.

The key ID is the key's RFC 7638 JWK thumbprint, which is also stored as the JWK's `kid`.

## The signing service

Request: `{"aud": "<authorization server issuer>", "kid": "<key ID>", "challenge": "<challenge>"}`, `kid` optional, and `challenge` only with App Attest headers (below).

- `aud` must be an `https://` origin (no path, query or fragment) and in `ALLOWED_ISSUERS`.
- With `kid`, sign with that key, or answer 409 if it's gone. Never fall back to another key: the server ends a session refreshed with a different key.
- Without `kid`, sign with the current key.

Response: `{"client_assertion": "<JWT>", "kid": "<key ID used>"}`. The JWT is ES256 with header `{"alg": "ES256", "kid": …, "typ": "JWT"}` and claims:

| Claim | Value |
| --- | --- |
| `iss`, `sub` | the client ID of the host asked, such as `https://flux.bespokebits.dev/oauth/client-metadata.json` |
| `aud` | the request's `aud` |
| `jti` | random, at least 128 bits, never reused |
| `iat` | now (Unix seconds) |
| `exp` | `iat` + 60 |

It never sees tokens. Its state is the day's count, outstanding challenges and registered App Attest public keys with their counters and receipts. It rate-limits by address (Influx asks once per PAR, token exchange and refresh, so a few a minute per device is plenty) and answers 429 with `Retry-After`, then applies the daily limit.

## Caller attestation (ADR 0033)

Influx proves with App Attest, on the iPhone and on the Mac (macOS 27 and later, from the main app bundle), that a request comes from a genuine install. The code is `src/callers.ts` (routes), `src/attest.ts` (Apple's checks), `src/cbor.ts` and `src/der.ts` (parsers) and `src/objects.ts` (Durable Objects).

1. `POST /oauth/challenge` answers `{"challenge": "<base64url of 32 random bytes>"}`, good once, for five minutes. Registrations and attested assertion requests use the same challenges, and each request needs a fresh one.
2. The app makes a key with `DCAppAttestService`, attests it over SHA-256 of the challenge string, and posts `POST /oauth/register` with `{"platform": "ios" | "mac", "appId": "<bundle ID>", "keyId": "<base64>", "attestation": "<base64>", "challenge": "<challenge>"}`. It answers 201 `{"keyId": "<base64>"}`.
3. For each assertion request the app takes another challenge, puts it in the body as `"challenge"`, and sends `X-Influx-Key: <key ID>` and `X-Influx-Assertion: <base64 assertion object>`, made over SHA-256 of the exact body bytes. An assertion request without those headers needs no challenge while `REQUIRE_ATTESTATION` is off.

Registration follows Apple's "Validating apps that connect to your server": the leaf and intermediate chain to the Apple App Attestation Root CA, all in date; the leaf's nonce extension (`1.2.840.113635.100.8.2`) is SHA-256(authData ‖ SHA-256(challenge)); the key ID is SHA-256 of the leaf's public key; and the authenticator data names `<team>.<bundle ID>`, has counter 0, the credential ID is the key ID, and the AAGUID is `appattest` for `dev.bespokebits.influx` and `appattestdevelop` for `dev.bespokebits.influx.dev`. A Mac key's leaf must also carry the aclBlob extension (`1.2.840.113635.100.8.6`) with exactly the full-security, SIP-on policy Apple gives (`MACOS_ACL_BLOB`), and any key that carries that extension must carry that policy.

Both the attestation's and every assertion's authenticator data must end in an extensions map, with the ED flag (0x80) set in its flags byte. In an attestation the map follows the attested credential data (the AAGUID, the credential ID and the key as a COSE map); in an assertion it follows the 37-byte header. Nothing may follow the map. In it:

| Entry | Must be |
| --- | --- |
| `apple_validation_category_01` | how the app was signed: 2 (TestFlight) or 4 (App Store) for `dev.bespokebits.influx`, 3 (development) for `dev.bespokebits.influx.dev` |
| `apple_bundle_version_01` | the app's bundle version, present, and not below `MIN_BUNDLE_VERSION` |

The key's record keeps the category and bundle version last attested, for information only, and the attestation statement's `receipt` (base64), unchecked, for a later fraud-risk check with Apple. A registration without a receipt is refused.

Some refusals are policy: the app is genuine, but the Worker doesn't accept that build. A new key can't fix them, so they answer 403 `app_not_accepted` rather than 401, on both routes:

- an app ID that isn't, or is no longer, one of the two above;
- a launch category the app ID doesn't allow;
- a bundle version below `MIN_BUNDLE_VERSION`, or not dotted numbers while a minimum is set;
- a Mac key without the trusted access policy, or any key with another one.

They are judged only after every other check has passed, so a forged attestation or assertion is never told it is a genuine app (`src/bytes.ts`, `Refusal.kind`). A missing category or version entry, or an extensions map that is unflagged or malformed, is not policy: Apple always writes both entries.

Registration answers:

| Answer | When |
| --- | --- |
| 400 `invalid_request` | the body isn't a JSON object with those fields, or `platform` is neither `ios` nor `mac` |
| 400 `bad_challenge` | the challenge is unknown, used or expired; it is spent before the attestation is checked |
| 401 `attestation_invalid` | any other check fails, including a missing receipt and malformed base64, CBOR or DER |
| 403 `app_not_accepted` | a policy refusal; an app ID it doesn't attest is refused before the challenge is spent |

An assertion is checked against the stored key, in this order: the signature over SHA-256(authenticatorData ‖ SHA-256(body)), the App ID in its authenticator data, its extensions and the policy, then the body's challenge, and last a counter above the last one accepted. The challenge is spent only after the signature and the policy check out, so a forged request can't use up someone else's, and a policy refusal leaves it unspent. A key unused for 90 days is forgotten.

| Answer | When | What the app does |
| --- | --- | --- |
| 401 `key_unknown` | the key was never registered, or was forgotten after 90 idle days | registers a new key |
| 401 `attestation_required` | any other attestation failure: a bad signature, the wrong App ID in the assertion, malformed extensions, a missing, unknown, expired or spent challenge, a counter that didn't rise, a malformed header; or no attestation at all while `REQUIRE_ATTESTATION` is `"true"` | retries once with a fresh challenge on the same key |
| 403 `app_not_accepted` | a policy refusal | stops: only another build can fix it |

## Field performance reports (ADR 0034)

TestFlight installs send MetricKit's daily figures, so performance is judged from ordinary use (`src/perf.ts`). The app sends one report per MetricKit payload, about one a day.

`POST /perf/report` takes `{"challenge": "<challenge>", "report": {…}}`, attested exactly like an assertion request: a fresh challenge from `/oauth/challenge`, and `X-Influx-Key` and `X-Influx-Assertion` over the exact body. Attestation is required whatever `REQUIRE_ATTESTATION` says. The report must have exactly these fields, `resume` and `sammyMedia` optional:

| Field | Must be |
| --- | --- |
| `id` | a random UUID, upper case, that the app made for this report alone; it names no install |
| `platform` | `ios` or `mac` |
| `build` | the app's `CFBundleVersion`: dotted digits, at most 20 characters |
| `os` | the OS version: dotted digits, at most 20 characters |
| `device` | the hardware model, such as `iPhone16,2`: 1 to 24 letters, digits and commas |
| `periodStart`, `periodEnd` | RFC 3339 times, the start not after the end: the payload's period |
| `scrollHitchMsPerS` | scroll hitch time in ms per second of scrolling, 0 to 1000, or `null` when nothing was measured |
| `launch` | time to first draw, as at most 24 buckets `{"startMs", "endMs", "count"}`: integers, 0 ≤ `startMs` < `endMs` ≤ 600000, 0 ≤ `count` ≤ 1000000 |
| `resume` | time to resume, the same shape |
| `sammyMedia` | what Sammy media grants did since the last report (ADR 0039): `avatar` and `attachment`, each exactly `{"grants", "grantsRateLimited", "bytesRateLimited", "heldBack", "deferred"}`, integers from 0 to 1000000: grants asked for, grant and byte requests the server answered with a 429, requests the app held back after one, and grants not asked for because the pictures' allowance was spent; since ADR 0040, `"direct"` and `"fallbacks"` too (both or neither, so a build before it is still taken): loads read straight from the source, and direct loads that fell back to a grant. Optionally `timeToImage`, exactly `{"direct", "grant"}`, each 7 counts from 0 to 1000000: images that arrived within 100, 250, 500, 1000, 2500 and 5000 ms and over, read each way (`TIME_TO_IMAGE_BOUNDS_MS`). Left out when nothing was counted |

| Answer | When |
| --- | --- |
| 204 | stored |
| 400 `invalid_request` | the body isn't a JSON object of `challenge` and `report` alone |
| 400 `invalid_report` | the report breaks the table above; it is checked before attestation, so its challenge isn't spent |
| 401 `key_unknown`, 401 `attestation_required` | as for an assertion request, and also for a report with no attestation at all |
| 403 `app_not_accepted` | a build the Worker doesn't accept, once `REQUIRE_ATTESTATION` is `"true"` |
| 403 `report_not_accepted` | the same, while attestation is optional: `app_not_accepted` would also stop that build's Bluesky sign-ins for the run, which assertions don't do yet |
| 503 `daily_limit` | the UTC day already has 200 reports |

The `PerfReports` object keeps one record per UTC day: that day's reports, each with `receivedAt`. Nothing about the caller is kept: no address, key ID or assertion. A day holds at most 200 reports, and when a day's first report arrives the days before the last 90 are removed. A report sent again with the same `id` (an app whose 204 was lost retries it) is answered 204 and not stored twice. The IDs taken, each with its day, are kept as `seen:` entries and removed with their days.

`GET /perf/reports?days=N` answers the reports and, per platform and build (iPhone first, newest build first):

- `reports`: how many;
- `scrollHitchMsPerS`: `{"reports", "median", "worst"}` over the reports that measured scrolling;
- `scrollHitchByDevice`: the same per hardware model, `[{"device", "reports", "median", "worst"}]`, since the bar is set on one phone;
- `launch` and `resume`: `{"reports", "count", "p50Ms", "p90Ms"}`: how many reports counted any, how many in all, and percentiles from every report's histogram added together, each bucket's launches taken as spread evenly across it;
- `sammyMedia`: `{"reports", "avatar", "attachment", "timeToImage"}`: how many reports carried Sammy media counts, each kind's counts added up over them (every count present; one a build didn't send adds nothing), and the time-to-image buckets added up the same way.

`scripts/perf-report.mjs` at the repository root reads it and checks each build against the bar.
