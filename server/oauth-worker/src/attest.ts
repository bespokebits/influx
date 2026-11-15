// App Attest checks, as Apple documents them in "Validating apps that
// connect to your server": an attestation when a key is registered, and an
// assertion with each request after. The iPhone and the Mac (macOS 27 and
// later, from the main app bundle) attest the same way, so there is one path.
// Every failure is a Refusal; nothing here throws anything else.

import { concat, equal, fromBase64, fromUtf8, refuse, refusePolicy, Refusal, sha256, utf8 } from "./bytes.ts";
import { decodeCbor, decodeCborItem, type CborValue } from "./cbor.ts";
import { APPLE_ROOT_CA_G3, verifyReceipt } from "./receipt.ts";
import { children, ecdsaSignatureToRaw, OID, parseCertificate, readOnly, TAG, verifySignedBy, type Certificate } from "./der.ts";

/**
 * Apple App Attestation Root CA, from
 * https://www.apple.com/certificateauthority/Apple_App_Attestation_Root_CA.pem
 * (fetched 2026-11-12). P-384, valid 2020-03-18 to 2045-03-15.
 * SHA-256 fingerprint of the DER:
 * 1C:B9:82:3B:A2:8B:A6:AD:2D:33:A0:06:94:1D:E2:AE:4F:51:3E:F1:D4:E8:31:B9:F7:E0:FA:7B:62:42:C9:32
 */
export const APPLE_APP_ATTESTATION_ROOT_CA = `-----BEGIN CERTIFICATE-----
MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYw
JAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwK
QXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNa
Fw00NTAzMTUwMDAwMDBaMFIxJjAkBgNVBAMMHUFwcGxlIEFwcCBBdHRlc3RhdGlv
biBSb290IENBMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9y
bmlhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdh
NbJhFs/Ii2FdCgAHGbpphY3+d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9au
Yen1mMEvRq9Sk3Jm5X8U62H+xTD3FE9TgS41o0IwQDAPBgNVHRMBAf8EBTADAQH/
MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNVHQ8BAf8EBAMCAQYw
CgYIKoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn
53O5+FRXgeLhpJ06ysC5PrOyAjEAp5U4xDgEgllF7En3VcE3iexZZtKeYnpqtijV
oyFraWVIyd/dganmrduC1bmTBGwD
-----END CERTIFICATE-----`;

/** The leaf certificate's extension holding the attestation's nonce. */
const NONCE_EXTENSION = "1.2.840.113635.100.8.2";

/** The leaf certificate's extension holding a macOS key's access policy, its "aclBlob". */
const ACL_BLOB_EXTENSION = "1.2.840.113635.100.8.6";

/**
 * The leaf's extension describing the device, undocumented: a SEQUENCE of
 * context-tagged fields with high tag numbers, each holding one value. Field
 * 1026 names the OS family ("macosx" on macOS 27.2), beside its version and
 * build in others.
 */
const DEVICE_EXTENSION = "1.2.840.113635.100.8.7";
const OS_FAMILY_FIELD = 1026;

/**
 * The only macOS key policy it trusts: full security mode with SIP on.
 * Apple's procedure ("Validating apps that connect to your server", on
 * macOS) says to take the octet string in the aclBlob extension and check
 * it equals exactly this, which it gives as base64.
 */
export const MACOS_ACL_BLOB = fromBase64("MEAMAjExMDowCQwCb2uhAwEB/zAJDAJvYaEDAQH/MAsMBG9kZWyhAwEB/zAVDARvc2duoAYMBHJzZWMwBaYDAgEB");

/**
 * The bundle IDs it attests, and which App Attest environment each signs
 * in: the release app in production, the debug app in development.
 */
export const ATTESTED_APPS: Readonly<Record<string, "production" | "development">> = {
  "dev.bespokebits.influx": "production",
  "dev.bespokebits.influx.dev": "development",
};

/** The authenticator data's AAGUID for an environment. */
export function aaguid(environment: "production" | "development"): Uint8Array {
  return environment === "production" ? concat(utf8("appattest"), new Uint8Array(7)) : utf8("appattestdevelop");
}

/**
 * Whether a key attested in the environment `found` names suits an app of
 * `environment`. The release app attests only in production. The debug app
 * may attest in either: macOS has no App Attest environment entitlement, and
 * a development-signed Mac app attests in production (seen on macOS 27.2).
 * Its launch category still has to be development signing.
 */
function aaguidSuits(found: Uint8Array, environment: "production" | "development"): boolean {
  if (equal(found, aaguid(environment))) return true;
  return environment === "development" && equal(found, aaguid("production"));
}

export function pemToDer(pem: string): Uint8Array {
  const body = pem.replace(/-----(BEGIN|END) CERTIFICATE-----/g, "").replace(/\s+/g, "");
  return fromBase64(body);
}

const ROOT_DER = pemToDer(APPLE_APP_ATTESTATION_ROOT_CA);

/** The roots an attestation and its receipt chain to: Apple's, everywhere but the tests. */
export interface Roots {
  appAttest: Uint8Array;
  receipt: Uint8Array;
}

export const APPLE_ROOTS: Roots = { appAttest: ROOT_DER, receipt: pemToDer(APPLE_ROOT_CA_G3) };

export interface Attestation {
  /** The attestation object from `attestKey`. */
  attestation: Uint8Array;
  /** The key ID from `generateKey`. */
  keyId: Uint8Array;
  /** The challenge the client hashed into `clientDataHash`. */
  challenge: string;
  /** The app's App ID: `<team ID>.<bundle ID>`. */
  appId: string;
  environment: "production" | "development";
  /** A Mac's key must carry the trusted access policy; an iPhone's may not carry another. */
  platform: "ios" | "mac";
  /** The lowest app version it accepts, dotted numbers; unset accepts any. */
  minBundleVersion?: string;
}

/** What the authenticator data's extensions say about the app that signed. */
export interface LaunchContext {
  /** How the app was signed: 2 TestFlight, 3 development, 4 App Store. */
  category: number;
  /**
   * The app's bundle version (CFBundleVersion). A development-signed app
   * may leave it out (seen on macOS 27.2); a distributed one must have it.
   */
  bundleVersion?: string;
}

/** What a verified attestation gives the Worker to keep. */
export interface VerifiedAttestation extends LaunchContext {
  /** The 65-byte uncompressed point. */
  publicKey: Uint8Array;
  /** The key's certificate (the attestation's first x5c entry), DER, as its receipts name it. */
  credCert: Uint8Array;
  receipt: Uint8Array;
  /** The environment the key attested in, which its receipts belong to. */
  environment: "production" | "development";
  /** The OS family its certificate names ("macosx"), when it names one. */
  os?: string;
}

/** Checks a new key's attestation and its receipt. */
export async function verifyAttestation(
  input: Attestation,
  roots: Roots = APPLE_ROOTS,
  now = Date.now(),
): Promise<VerifiedAttestation> {
  return refusing(async () => {
    const object = map(decodeCbor(input.attestation), "attestation");
    if (field(object, "fmt") !== "apple-appattest") refuse("attestation: format");
    const statement = map(field(object, "attStmt"), "attStmt");
    const x5c = field(statement, "x5c");
    if (!Array.isArray(x5c) || x5c.length < 2) refuse("attestation: x5c");
    // Checked below, and kept so the install's risk metric can be asked of Apple.
    const receipt = bytes(field(statement, "receipt"), "receipt");
    if (receipt.length === 0) refuse("receipt: empty");
    const authData = bytes(field(object, "authData"), "authData");

    // 1. The leaf and intermediate chain to Apple's root, and all three are
    // in date.
    const anchor = parseCertificate(roots.appAttest);
    const intermediate = parseCertificate(bytes(x5c[1], "intermediate"));
    const leaf = parseCertificate(bytes(x5c[0], "leaf"));
    for (const certificate of [anchor, intermediate, leaf]) {
      if (now < certificate.notBefore || now > certificate.notAfter) refuse("chain: certificate out of date");
    }
    await verifySignedBy(intermediate, anchor);
    await verifySignedBy(leaf, intermediate);

    // 2 and 3. The nonce in the leaf is SHA-256(authData || SHA-256(challenge)).
    const clientDataHash = await sha256(utf8(input.challenge));
    const nonce = await sha256(concat(authData, clientDataHash));
    const extension = leaf.extensions.get(NONCE_EXTENSION);
    if (!extension) refuse("nonce: missing");
    if (!equal(embeddedNonce(extension), nonce)) refuse("nonce: mismatch");
    // Read now, so a malformed one is invalid; judged with the policy below.
    const aclExtension = leaf.extensions.get(ACL_BLOB_EXTENSION);
    const acl = aclExtension && aclBlob(aclExtension);

    // 4. The key ID is the SHA-256 of the leaf's public key.
    const publicKey = leafKey(leaf);
    if (!equal(await sha256(publicKey), input.keyId)) refuse("keyId: not the leaf's key");

    // 5. The authenticator data names this app, a fresh key, the app's
    // environment and the same key.
    if (authData.length < 55) refuse("authData: truncated");
    if (!equal(authData.subarray(0, 32), await sha256(utf8(input.appId)))) refuse("authData: rpIdHash");
    if (counterOf(authData) !== 0) refuse("authData: counter");
    const found = authData.subarray(37, 53);
    if (!aaguidSuits(found, input.environment)) refuse("authData: aaguid");
    const environment = equal(found, aaguid("production")) ? "production" : "development";
    const length = (authData[53] << 8) | authData[54];
    if (authData.length < 55 + length) refuse("authData: truncated");
    if (!equal(authData.subarray(55, 55 + length), input.keyId)) refuse("authData: credentialId");

    // 6. The extensions follow the attested credential data, which ends with
    // the key as a COSE map of whatever length it encodes to.
    const { value: coseKey, next } = decodeCborItem(authData, 55 + length);
    if (!(coseKey instanceof Map)) refuse("authData: COSE key");
    const context = readLaunchContext(authData, next);

    // 7. The receipt: Apple signed it, for this app and this key, within
    // the last five minutes.
    const credCert = bytes(x5c[0], "leaf");
    await verifyReceipt({ receipt, appId: input.appId, credCert, type: "ATTEST" }, roots.receipt, now);

    // 8. Policy, judged last so that only an attestation that is genuine in
    // every other way hears it. A Mac key must have full security mode and
    // SIP, as Apple's procedure says for macOS. An iPhone key carries an
    // access policy of its own (seen on iOS 27), which Apple doesn't ask to
    // check. A key whose certificate says it was made on macOS is a Mac's,
    // whatever the caller claims, so a Mac can't skip the check by calling
    // itself an iPhone.
    const os = osFamily(leaf);
    if (input.platform === "mac" || os === "macosx") {
      if (!acl) refusePolicy("aclBlob: missing");
      if (!equal(acl, MACOS_ACL_BLOB)) refusePolicy("aclBlob: untrusted policy");
    }
    acceptLaunchContext(context, input.environment, input.minBundleVersion);
    return { publicKey, credCert, receipt, environment, ...(os ? { os } : {}), ...context };
  });
}

export interface Assertion {
  /** The assertion object from `generateAssertion`. */
  assertion: Uint8Array;
  /** The exact bytes whose SHA-256 the client passed as `clientDataHash`. */
  clientData: Uint8Array;
  /** The registered key, the 65-byte uncompressed point. */
  publicKey: Uint8Array;
  appId: string;
  /**
   * The environment of the app the key was attested for; none when that
   * app is no longer accepted, which refuses a genuine assertion as policy.
   */
  environment: "production" | "development" | undefined;
  minBundleVersion?: string;
}

/**
 * Checks an assertion and returns its counter and launch context. The
 * caller checks the counter against the last one it stored and stores this
 * one, and checks the challenge in the client data.
 */
export async function verifyAssertion(input: Assertion): Promise<{ counter: number } & LaunchContext> {
  return refusing(async () => {
    const object = map(decodeCbor(input.assertion), "assertion");
    const signature = bytes(field(object, "signature"), "signature");
    const authenticatorData = bytes(field(object, "authenticatorData"), "authenticatorData");
    if (authenticatorData.length < 37) refuse("assertion: authenticatorData truncated");
    const clientDataHash = await sha256(input.clientData);
    const nonce = await sha256(concat(authenticatorData, clientDataHash));
    const key = await crypto.subtle.importKey("raw", input.publicKey, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
    // The Secure Enclave signs the nonce, so the ECDSA digest is
    // SHA-256(nonce): WebCrypto hashes the message it is given.
    const valid = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, ecdsaSignatureToRaw(signature, 32), nonce);
    if (!valid) refuse("assertion: signature");
    if (!equal(authenticatorData.subarray(0, 32), await sha256(utf8(input.appId)))) refuse("assertion: rpIdHash");
    // An assertion has no attested credential data, so its extensions start
    // straight after the 37-byte header.
    const context = readLaunchContext(authenticatorData, 37);
    if (!input.environment) refusePolicy("assertion: app no longer accepted");
    acceptLaunchContext(context, input.environment, input.minBundleVersion);
    return { counter: counterOf(authenticatorData), ...context };
  });
}

/** The authenticator data's flag saying extensions follow (WebAuthn's ED). */
const EXTENSIONS_FLAG = 0x80;

/** Which launch categories each environment's app may run as. */
const CATEGORIES: Record<"production" | "development", readonly number[]> = {
  // The release app comes from TestFlight (2) or the App Store (4).
  production: [2, 4],
  // The debug app is development-signed (3).
  development: [3],
};

/**
 * Reads the extensions map that ends the authenticator data at `offset`.
 * A map that is missing or malformed, or has no launch category, is
 * invalid. Apple documents the category as a UInt32; a real attestation
 * (macOS 27.2) carries it as four bytes, little-endian, so both are read.
 * A missing bundle version is judged by `acceptLaunchContext`.
 */
function readLaunchContext(authData: Uint8Array, offset: number): LaunchContext {
  if (!(authData[32] & EXTENSIONS_FLAG)) refuse("extensions: flag not set");
  const { value, next } = decodeCborItem(authData, offset);
  if (next !== authData.length) refuse("extensions: trailing bytes");
  if (!(value instanceof Map)) refuse("extensions: not a map");
  const raw = value.get("apple_validation_category_01");
  let category: number;
  if (typeof raw === "number") category = raw;
  else if (raw instanceof Uint8Array && raw.length === 4) category = new DataView(raw.buffer, raw.byteOffset, 4).getUint32(0, true);
  else refuse("extensions: launch category missing");
  const bundleVersion = value.get("apple_bundle_version_01");
  if (bundleVersion !== undefined && typeof bundleVersion !== "string") refuse("extensions: bundle version not a string");
  return bundleVersion === undefined ? { category } : { category, bundleVersion };
}

/**
 * Whether the Worker accepts a build: its launch category suits its app,
 * and its bundle version isn't below the minimum. A refusal here is policy.
 */
function acceptLaunchContext(context: LaunchContext, environment: "production" | "development", minBundleVersion?: string): void {
  if (!CATEGORIES[environment].includes(context.category)) refusePolicy("extensions: launch category");
  // Only a development-signed build may leave its version out, and then no
  // minimum applies to it.
  if (context.bundleVersion === undefined) {
    if (environment === "development") return;
    refuse("extensions: bundle version missing");
  }
  // Without a minimum, any version will do; with one, it must be a version
  // that can be compared, and not below it.
  if (minBundleVersion && compareVersions(parseVersion(context.bundleVersion), parseVersion(minBundleVersion)) < 0) {
    refusePolicy("extensions: bundle version too old");
  }
}

/** A dotted numeric version, such as "0.1.0", as its numbers. */
function parseVersion(text: string): number[] {
  if (!/^\d{1,9}(\.\d{1,9})*$/.test(text)) refusePolicy("extensions: bundle version malformed");
  return text.split(".").map(Number);
}

/** Below zero when a is older than b; missing parts count as 0, so "1" equals "1.0". */
function compareVersions(a: number[], b: number[]): number {
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    const difference = (a[i] ?? 0) - (b[i] ?? 0);
    if (difference !== 0) return difference;
  }
  return 0;
}

/** Runs a check, turning anything it throws (a WebCrypto error, say) into a Refusal. */
async function refusing<T>(check: () => Promise<T>): Promise<T> {
  try {
    return await check();
  } catch (error) {
    if (error instanceof Refusal) throw error;
    throw new Refusal(`unexpected: ${error instanceof Error ? error.name : "error"}`);
  }
}

function map(value: CborValue, name: string): Map<string | number, CborValue> {
  if (!(value instanceof Map)) refuse(`${name}: not a map`);
  return value;
}

function field(value: Map<string | number, CborValue>, key: string): CborValue {
  const out = value.get(key);
  if (out === undefined) refuse(`${key}: missing`);
  return out;
}

function bytes(value: CborValue, name: string): Uint8Array {
  if (!(value instanceof Uint8Array)) refuse(`${name}: not bytes`);
  return value;
}

/** The big-endian sign count at bytes 33 to 36 of authenticator data. */
function counterOf(authData: Uint8Array): number {
  return ((authData[33] << 24) >>> 0) + (authData[34] << 16) + (authData[35] << 8) + authData[36];
}

/** The nonce in `SEQUENCE { [1] EXPLICIT { OCTET STRING nonce } }`. */
function embeddedNonce(extension: Uint8Array): Uint8Array {
  const tagged = children(readOnly(extension, TAG.SEQUENCE)).find((child) => child.tag === 0xa1);
  if (!tagged) refuse("nonce: malformed");
  return readOnly(tagged.contents, TAG.OCTET_STRING).contents;
}

/**
 * The aclBlob extension's OCTET STRING. A real Mac attestation (macOS 27.2)
 * wraps it like the nonce: SEQUENCE { [3] { OCTET STRING } }.
 */
function aclBlob(extension: Uint8Array): Uint8Array {
  const parts = children(readOnly(extension, TAG.SEQUENCE));
  if (parts.length !== 1 || parts[0].tag !== 0xa3) refuse("aclBlob: malformed");
  return readOnly(parts[0].contents, TAG.OCTET_STRING).contents;
}

/**
 * The OS family the leaf's device extension names, or nothing when it has
 * none or it can't be read. Undocumented, so it only ever adds a check: a
 * certificate that can't be read is judged by the platform claimed.
 */
function osFamily(leaf: Certificate): string | undefined {
  const extension = leaf.extensions.get(DEVICE_EXTENSION);
  if (!extension) return undefined;
  try {
    const sequence = readOnly(extension, TAG.SEQUENCE).contents;
    for (let at = 0; at < sequence.length; ) {
      // A context-specific, constructed tag with a high tag number: 0xBF,
      // then the number in base 128.
      if (sequence[at++] !== 0xbf) return undefined;
      let field = 0;
      for (let byte = 0x80, digits = 0; byte & 0x80; digits++) {
        if (digits === 4 || at >= sequence.length) return undefined;
        byte = sequence[at++];
        field = field * 128 + (byte & 0x7f);
      }
      // Then an ordinary length, and the field: one element holding its value.
      if (at >= sequence.length) return undefined;
      let length = sequence[at++];
      if (length & 0x80) {
        const width = length & 0x7f;
        if (width < 1 || width > 2 || at + width > sequence.length) return undefined;
        length = 0;
        for (let i = 0; i < width; i++) length = length * 256 + sequence[at++];
      }
      const end = at + length;
      if (end > sequence.length) return undefined;
      if (field === OS_FAMILY_FIELD) {
        const value = readOnly(sequence.subarray(at, end));
        return value.tag === TAG.OCTET_STRING ? fromUtf8(value.contents) : undefined;
      }
      at = end;
    }
  } catch {
    return undefined;
  }
  return undefined;
}

/** The leaf's P-256 public key as an uncompressed point. */
function leafKey(leaf: Certificate): Uint8Array {
  const { algorithm, curve, key } = leaf.publicKey;
  if (algorithm !== OID.EC_PUBLIC_KEY || curve !== OID.P256 || key.length !== 65 || key[0] !== 0x04) refuse("leaf: not a P-256 key");
  return key;
}

