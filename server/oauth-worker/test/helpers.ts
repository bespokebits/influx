// Test helpers: a small DER and CBOR encoder, and a stand-in App Attest PKI
// (a P-384 root and intermediate, P-256 leaves) built with WebCrypto, so
// the attestation checks run against real signatures with no network.

import { AttestedKey, Challenges, DailyCount, PerfReports, type Env } from "../src/index.ts";
import type { Namespace, State } from "../src/objects.ts";

export const enc = new TextEncoder();

export function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let offset = 0;
  for (const part of parts) (out.set(part, offset), (offset += part.length));
  return out;
}

export async function sha256(bytes: Uint8Array): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
}

export const b64 = (bytes: Uint8Array) => Buffer.from(bytes).toString("base64");

// DER

export function tlv(tag: number, ...parts: Uint8Array[]): Uint8Array {
  const body = concat(...parts);
  const length: number[] = [];
  if (body.length < 0x80) length.push(body.length);
  else {
    for (let n = body.length; n > 0; n = Math.floor(n / 256)) length.unshift(n & 0xff);
    length.unshift(0x80 | length.length);
  }
  return concat(new Uint8Array([tag, ...length]), body);
}

export const seq = (...parts: Uint8Array[]) => tlv(0x30, ...parts);
export const set = (...parts: Uint8Array[]) => tlv(0x31, ...parts);
export const octets = (bytes: Uint8Array) => tlv(0x04, bytes);
export const bits = (bytes: Uint8Array) => tlv(0x03, new Uint8Array([0]), bytes);
export const explicit = (n: number, ...parts: Uint8Array[]) => tlv(0xa0 + n, ...parts);

export function oid(dotted: string): Uint8Array {
  const [first, second, ...rest] = dotted.split(".").map(Number);
  const out = [first * 40 + second];
  for (const arc of rest) {
    const group = [arc & 0x7f];
    for (let n = Math.floor(arc / 128); n > 0; n = Math.floor(n / 128)) group.unshift((n & 0x7f) | 0x80);
    out.push(...group);
  }
  return tlv(0x06, new Uint8Array(out));
}

export function integer(bytes: Uint8Array): Uint8Array {
  let i = 0;
  while (i < bytes.length - 1 && bytes[i] === 0) i++;
  const trimmed = bytes.subarray(i);
  return tlv(0x02, trimmed[0] & 0x80 ? concat(new Uint8Array([0]), trimmed) : trimmed);
}

function utcTime(date: Date): Uint8Array {
  const iso = date.toISOString();
  const text = iso.slice(2, 4) + iso.slice(5, 7) + iso.slice(8, 10) + iso.slice(11, 13) + iso.slice(14, 16) + iso.slice(17, 19) + "Z";
  return tlv(0x17, enc.encode(text));
}

export const name = (cn: string) => seq(set(seq(oid("2.5.4.3"), tlv(0x0c, enc.encode(cn)))));

export const ECDSA_SHA256 = "1.2.840.10045.4.3.2";
export const ECDSA_SHA384 = "1.2.840.10045.4.3.3";
export const NONCE_OID = "1.2.840.113635.100.8.2";

/** A raw r || s signature as DER. */
export function derSignature(raw: Uint8Array): Uint8Array {
  const half = raw.length / 2;
  return seq(integer(raw.subarray(0, half)), integer(raw.subarray(half)));
}

export interface Keys {
  privateKey: CryptoKey;
  spki: Uint8Array;
  /** The uncompressed point. */
  point: Uint8Array;
}

export async function ecKeys(curve: "P-256" | "P-384"): Promise<Keys> {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: curve }, true, ["sign", "verify"])) as CryptoKeyPair;
  return {
    privateKey: pair.privateKey,
    spki: new Uint8Array(await crypto.subtle.exportKey("spki", pair.publicKey)),
    point: new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey)),
  };
}

export async function certificate(options: {
  subject: string;
  issuer: string;
  spki: Uint8Array;
  signer: CryptoKey;
  serial?: Uint8Array;
  algorithm?: string;
  notBefore?: Date;
  notAfter?: Date;
  extensions?: Uint8Array[];
}): Promise<Uint8Array> {
  const algorithm = options.algorithm ?? ECDSA_SHA384;
  const hash = algorithm === ECDSA_SHA256 ? "SHA-256" : "SHA-384";
  const algorithmId = seq(oid(algorithm));
  const tbs = seq(
    explicit(0, integer(new Uint8Array([2]))),
    integer(options.serial ?? crypto.getRandomValues(new Uint8Array(8))),
    algorithmId,
    name(options.issuer),
    seq(utcTime(options.notBefore ?? new Date(Date.now() - 86_400_000)), utcTime(options.notAfter ?? new Date(Date.now() + 86_400_000))),
    name(options.subject),
    options.spki,
    ...(options.extensions?.length ? [explicit(3, seq(...options.extensions))] : []),
  );
  const raw = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash }, options.signer, tbs));
  return seq(tbs, algorithmId, bits(derSignature(raw)));
}

// CBOR

function head(major: number, n: number): Uint8Array {
  if (n < 24) return new Uint8Array([(major << 5) | n]);
  if (n < 0x100) return new Uint8Array([(major << 5) | 24, n]);
  if (n < 0x10000) return new Uint8Array([(major << 5) | 25, n >> 8, n & 0xff]);
  return new Uint8Array([(major << 5) | 26, n >>> 24, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff]);
}

export function cbor(value: unknown): Uint8Array {
  if (value instanceof Uint8Array) return concat(head(2, value.length), value);
  if (typeof value === "string") {
    const bytes = enc.encode(value);
    return concat(head(3, bytes.length), bytes);
  }
  if (typeof value === "number") return value >= 0 ? head(0, value) : head(1, -1 - value);
  if (value === false) return new Uint8Array([0xf4]);
  if (value === true) return new Uint8Array([0xf5]);
  if (value === null) return new Uint8Array([0xf6]);
  if (Array.isArray(value)) return concat(head(4, value.length), ...value.map(cbor));
  // A Map keeps integer keys, as a COSE key has.
  const entries = value instanceof Map ? [...value.entries()] : Object.entries(value as Record<string, unknown>);
  return concat(head(5, entries.length), ...entries.flatMap(([k, v]) => [cbor(k), cbor(v)]));
}

// A stand-in for Apple's App Attest PKI.

export const TEAM = "TEAMID1234";
export const RELEASE = "dev.bespokebits.influx";
export const DEBUG = "dev.bespokebits.influx.dev";
export const AAGUID_PRODUCTION = concat(enc.encode("appattest"), new Uint8Array(7));
export const AAGUID_DEVELOPMENT = enc.encode("appattestdevelop");

export interface Pki {
  root: Keys;
  rootCertificate: Uint8Array;
  intermediate: Keys;
  intermediateCertificate: Uint8Array;
  /** A stand-in for Root CA G3, its Application Integration CA and the receipt signer. */
  receipt: ReceiptPki;
  /** Both roots, as the Worker takes them. */
  roots: { appAttest: Uint8Array; receipt: Uint8Array };
}

export interface ReceiptPki {
  rootCertificate: Uint8Array;
  intermediateCertificate: Uint8Array;
  signer: Keys;
  signerCertificate: Uint8Array;
  signerSerial: Uint8Array;
}

export const INTEGRATION_CA_OID = "1.2.840.113635.100.6.2.3";
export const RECEIPT_SIGNER_OID = "1.2.840.113635.100.12.15";
const NULL = new Uint8Array([0x05, 0x00]);

/** A receipt chain under its own root, its CAs marked as Apple's are, unless `marks` is false. */
export async function makeReceiptPki(marks = true): Promise<ReceiptPki> {
  const root = await ecKeys("P-384");
  const intermediate = await ecKeys("P-384");
  const signer = await ecKeys("P-256");
  const signerSerial = crypto.getRandomValues(new Uint8Array(16));
  signerSerial[0] &= 0x7f;
  signerSerial[0] |= 0x01;
  return {
    rootCertificate: await certificate({ subject: "Test Root CA - G3", issuer: "Test Root CA - G3", spki: root.spki, signer: root.privateKey }),
    intermediateCertificate: await certificate({
      subject: "Test Application Integration CA",
      issuer: "Test Root CA - G3",
      spki: intermediate.spki,
      signer: root.privateKey,
      extensions: marks ? [seq(oid(INTEGRATION_CA_OID), octets(NULL))] : [],
    }),
    signer,
    signerSerial,
    signerCertificate: await certificate({
      subject: "Test Fraud Receipt Signing",
      issuer: "Test Application Integration CA",
      spki: signer.spki,
      signer: intermediate.privateKey,
      serial: signerSerial,
      algorithm: ECDSA_SHA256,
      extensions: marks ? [seq(oid(RECEIPT_SIGNER_OID), octets(NULL))] : [],
    }),
  };
}

export interface ReceiptOptions {
  appId: string;
  credCert: Uint8Array;
  type?: string;
  created?: Date;
  /** Extra or replacement fields, by number; null leaves one out. */
  fields?: Record<number, Uint8Array | string | null>;
  /** Signs a different payload from the one sent. */
  signedPayload?: Uint8Array;
  /** DER throughout, rather than Apple's BER with indefinite lengths and a chunked payload. */
  der?: boolean;
}

/** BER with an indefinite length, as Apple writes its receipts. */
const ber = (tag: number, ...parts: Uint8Array[]) => concat(new Uint8Array([tag, 0x80]), ...parts, new Uint8Array([0, 0]));

/** An App Attest receipt as Apple makes one: PKCS #7 signed data, signed by the receipt signer with no signed attributes. */
export async function makeReceipt(pki: ReceiptPki, options: ReceiptOptions): Promise<Uint8Array> {
  const created = options.created ?? new Date();
  const values: Record<number, Uint8Array | string | null> = {
    2: options.appId,
    3: options.credCert,
    4: new Uint8Array(32),
    5: "token",
    6: options.type ?? "ATTEST",
    7: "production",
    12: created.toISOString(),
    21: new Date(created.getTime() + 90 * 86_400_000).toISOString(),
    ...options.fields,
  };
  const field = (n: number, value: Uint8Array | string) =>
    seq(integer(new Uint8Array([n])), integer(new Uint8Array([1])), octets(typeof value === "string" ? enc.encode(value) : value));
  const payload = set(...Object.entries(values).flatMap(([n, value]) => (value === null ? [] : [field(Number(n), value)])));
  const raw = new Uint8Array(
    await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pki.signer.privateKey, options.signedPayload ?? payload),
  );
  const signerInfo = seq(
    integer(new Uint8Array([1])),
    seq(name("Test Application Integration CA"), integer(pki.signerSerial)),
    seq(oid("2.16.840.1.101.3.4.2.1"), NULL),
    seq(oid(ECDSA_SHA256)),
    octets(derSignature(raw)),
  );
  const algorithms = set(seq(oid("2.16.840.1.101.3.4.2.1"), NULL));
  const certificates = [pki.signerCertificate, pki.intermediateCertificate, pki.rootCertificate];
  if (options.der) {
    return seq(
      oid("1.2.840.113549.1.7.2"),
      explicit(0, seq(integer(new Uint8Array([1])), algorithms, seq(oid("1.2.840.113549.1.7.1"), explicit(0, octets(payload))), tlv(0xa0, ...certificates), set(signerInfo))),
    );
  }
  const half = Math.floor(payload.length / 2);
  return ber(
    0x30,
    oid("1.2.840.113549.1.7.2"),
    ber(
      0xa0,
      ber(
        0x30,
        integer(new Uint8Array([1])),
        algorithms,
        ber(0x30, oid("1.2.840.113549.1.7.1"), ber(0xa0, ber(0x24, octets(payload.subarray(0, half)), octets(payload.subarray(half))))),
        ber(0xa0, ...certificates),
        set(signerInfo),
      ),
    ),
  );
}

export async function makePki(rootName = "Test App Attestation Root CA"): Promise<Pki> {
  const root = await ecKeys("P-384");
  const intermediate = await ecKeys("P-384");
  const rootCertificate = await certificate({ subject: rootName, issuer: rootName, spki: root.spki, signer: root.privateKey });
  const receipt = await makeReceiptPki();
  return {
    root,
    rootCertificate,
    intermediate,
    intermediateCertificate: await certificate({
      subject: "Test App Attestation CA 1",
      issuer: rootName,
      spki: intermediate.spki,
      signer: root.privateKey,
    }),
    receipt,
    roots: { appAttest: rootCertificate, receipt: receipt.rootCertificate },
  };
}

export interface AttestationOptions {
  challenge: string;
  bundle?: string;
  team?: string;
  aaguid?: Uint8Array;
  counter?: number;
  /** Overrides the key ID used in the request and the credential ID. */
  keyId?: Uint8Array;
  credentialId?: Uint8Array;
  nonce?: Uint8Array;
  leafNotAfter?: Date;
  intermediateCertificate?: Uint8Array;
  fmt?: string;
  /** A key access policy for the leaf's aclBlob extension, as a Mac key has. */
  aclBlob?: Uint8Array;
  /** The OS family for the leaf's device extension ("macosx"), or raw bytes for the whole extension. */
  deviceOs?: string | Uint8Array;
  /** The authenticator data's launch context; see `extensions`. */
  launch?: Launch;
  /** The attestation statement's receipt; null leaves it out. */
  receipt?: unknown;
}

/**
 * What the authenticator data says about the app. `category` and
 * `bundleVersion` of null leave that entry out; `flag: false` clears the ED
 * flag; `raw` replaces the encoded extensions with any bytes.
 */
export interface Launch {
  category?: number | null;
  bundleVersion?: string | null;
  flag?: boolean;
  raw?: Uint8Array;
}

/** The flags byte and extensions for a launch context, by default a TestFlight 0.1.0 build. */
function extensions(launch: Launch, base: number, bundle: string): { flags: number; bytes: Uint8Array } {
  const category = launch.category === undefined ? (bundle === DEBUG ? 3 : 2) : launch.category;
  const bundleVersion = launch.bundleVersion === undefined ? "0.1.0" : launch.bundleVersion;
  const map: Record<string, unknown> = {};
  // As a real attestation carries it: four bytes, little-endian.
  if (category !== null) {
    const encoded = new Uint8Array(4);
    new DataView(encoded.buffer).setUint32(0, category, true);
    map.apple_validation_category_01 = encoded;
  }
  if (bundleVersion !== null) map.apple_bundle_version_01 = bundleVersion;
  return { flags: launch.flag === false ? base : base | 0x80, bytes: launch.raw ?? cbor(map) };
}

/** A P-256 public key as a COSE_Key map (RFC 9053): EC2, ES256, P-256, x, y. */
function coseKey(point: Uint8Array): Uint8Array {
  return cbor(new Map<number, unknown>([[1, 2], [3, -7], [-1, 1], [-2, point.slice(1, 33)], [-3, point.slice(33, 65)]]));
}

export const ACL_BLOB_OID = "1.2.840.113635.100.8.6";
export const DEVICE_OID = "1.2.840.113635.100.8.7";

/** A high-tag-number field as the device extension writes one: 0xBF, the number in base 128, a length, one element. */
function deviceField(number: number, value: Uint8Array): Uint8Array {
  const digits = [number & 0x7f];
  for (let n = Math.floor(number / 128); n > 0; n = Math.floor(n / 128)) digits.unshift((n & 0x7f) | 0x80);
  return concat(new Uint8Array([0xbf, ...digits, value.length]), value);
}

/** The device extension as a real Mac's has it: the OS version, a flag, then the OS family (field 1026). */
export function deviceExtension(os: string): Uint8Array {
  return seq(deviceField(1400, octets(enc.encode("27.2.1"))), deviceField(1104, integer(new Uint8Array([2]))), deviceField(1026, octets(enc.encode(os))));
}
/** The policy Apple says a trusted Mac key has: full security mode with SIP. */
export const TRUSTED_ACL_BLOB = new Uint8Array(
  Buffer.from("MEAMAjExMDowCQwCb2uhAwEB/zAJDAJvYaEDAQH/MAsMBG9kZWyhAwEB/zAVDARvc2duoAYMBHJzZWMwBaYDAgEB", "base64"),
);

export interface MadeAttestation {
  attestation: Uint8Array;
  keyId: Uint8Array;
  leaf: Keys;
}

export async function makeAttestation(pki: Pki, options: AttestationOptions): Promise<MadeAttestation> {
  const leaf = await ecKeys("P-256");
  const keyId = options.keyId ?? (await sha256(leaf.point));
  const credentialId = options.credentialId ?? keyId;
  const bundle = options.bundle ?? RELEASE;
  const aaguid = options.aaguid ?? (bundle === DEBUG ? AAGUID_DEVELOPMENT : AAGUID_PRODUCTION);
  const counter = new Uint8Array(4);
  new DataView(counter.buffer).setUint32(0, options.counter ?? 0);
  // AT (0x40): attested credential data follows, then the extensions.
  const launch = extensions(options.launch ?? {}, 0x40, bundle);
  const authData = concat(
    await sha256(enc.encode(`${options.team ?? TEAM}.${bundle}`)),
    new Uint8Array([launch.flags]),
    counter,
    aaguid,
    new Uint8Array([credentialId.length >> 8, credentialId.length & 0xff]),
    credentialId,
    coseKey(leaf.point),
    launch.bytes,
  );
  const nonce = options.nonce ?? (await sha256(concat(authData, await sha256(enc.encode(options.challenge)))));
  const leafCertificate = await certificate({
    subject: "leaf",
    issuer: "Test App Attestation CA 1",
    spki: leaf.spki,
    signer: pki.intermediate.privateKey,
    algorithm: ECDSA_SHA256,
    notAfter: options.leafNotAfter,
    extensions: [
      seq(oid(NONCE_OID), octets(seq(explicit(1, octets(nonce))))),
      ...(options.deviceOs === undefined ? [] : [seq(oid(DEVICE_OID), octets(typeof options.deviceOs === "string" ? deviceExtension(options.deviceOs) : options.deviceOs))]),
      // As a real Mac attestation carries it: SEQUENCE { [3] { OCTET STRING } }.
      ...(options.aclBlob ? [seq(oid(ACL_BLOB_OID), octets(seq(explicit(3, octets(options.aclBlob)))))] : []),
    ],
  });
  const attestation = cbor({
    fmt: options.fmt ?? "apple-appattest",
    attStmt: {
      x5c: [leafCertificate, options.intermediateCertificate ?? pki.intermediateCertificate],
      ...(options.receipt === null
        ? {}
        : { receipt: options.receipt ?? (await makeReceipt(pki.receipt, { appId: `${options.team ?? TEAM}.${bundle}`, credCert: leafCertificate })) }),
    },
    authData,
  });
  return { attestation, keyId, leaf };
}

/** An assertion as `generateAssertion` makes one, over SHA-256 of `clientData`. */
export async function makeAssertion(
  leaf: Keys,
  clientData: Uint8Array,
  counter: number,
  appId = `${TEAM}.${RELEASE}`,
  launch: Launch = {},
): Promise<Uint8Array> {
  const count = new Uint8Array(4);
  new DataView(count.buffer).setUint32(0, counter);
  // No attested credential data: the extensions follow the 37-byte header.
  const { flags, bytes } = extensions(launch, 0x00, appId.endsWith(`.${DEBUG}`) ? DEBUG : RELEASE);
  const authenticatorData = concat(await sha256(enc.encode(appId)), new Uint8Array([flags]), count, bytes);
  const nonce = await sha256(concat(authenticatorData, await sha256(clientData)));
  // The Secure Enclave signs the nonce with ECDSA over its SHA-256.
  const raw = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, leaf.privateKey, nonce));
  return cbor({ signature: derSignature(raw), authenticatorData });
}

// The Worker's environment.

/** Lets every other pending request run, as a real storage call can. */
const yieldToOthers = () => new Promise<void>((resolve) => setImmediate(resolve));

/**
 * Storage that behaves like a Durable Object's, in memory. Each call yields
 * before it acts, so requests that interleave in a real object interleave
 * here too, and a read-compare-write that isn't atomic shows it.
 */
export function memoryStorage() {
  const map = new Map<string, unknown>();
  /** Every write, in order, for checking what a race left behind. */
  const writes: [string, unknown][] = [];
  return {
    map,
    writes,
    get: async <T>(key: string) => (await yieldToOthers(), structuredClone(map.get(key)) as T | undefined),
    /** One key, or several at once as a Durable Object writes them: all in one step. */
    put: async (key: string | Record<string, unknown>, value?: unknown) => {
      await yieldToOthers();
      const entries = typeof key === "string" ? [[key, value] as const] : Object.entries(key);
      if (entries.length > 128) throw new RangeError("put: more than 128 keys");
      for (const [name, each] of entries) {
        writes.push([name, structuredClone(each)]);
        map.set(name, structuredClone(each));
      }
    },
    delete: async (keys: string | string[]) => {
      await yieldToOthers();
      // As a Durable Object's storage, which refuses more in one call.
      if (Array.isArray(keys) && keys.length > 128) throw new RangeError("delete: more than 128 keys");
      [keys].flat().forEach((key) => map.delete(key));
    },
    list: async <T>(options: { start?: string; end?: string } = {}) => {
      await yieldToOthers();
      const keys = [...map.keys()].sort().filter((key) => (options.start === undefined || key >= options.start) && (options.end === undefined || key < options.end));
      return new Map(keys.map((key) => [key, structuredClone(map.get(key))])) as Map<string, T>;
    },
  };
}

/**
 * A Durable Object's state, in memory. `blockConcurrencyWhile` really runs
 * one callback at a time, in order, as the real one holds every other event
 * until its callback is done.
 */
export function memoryState(storage = memoryStorage()) {
  let queue: Promise<unknown> = Promise.resolve();
  return {
    storage,
    blockConcurrencyWhile<T>(callback: () => Promise<T>): Promise<T> {
      const run = queue.then(callback);
      queue = run.catch(() => undefined);
      return run;
    },
  };
}

/** A namespace with one object per name, each with its own storage. */
export function namespace(make: (state: State) => { fetch(request: Request): Promise<Response> }) {
  const objects = new Map<string, { object: { fetch(request: Request): Promise<Response> }; storage: ReturnType<typeof memoryStorage> }>();
  const entry = (id: string) => {
    if (!objects.has(id)) {
      const state = memoryState();
      objects.set(id, { object: make(state), storage: state.storage });
    }
    return objects.get(id)!;
  };
  const binding: Namespace = { idFromName: (name) => name, get: (id) => entry(id as string).object };
  return { binding, storage: (name: string) => entry(name).storage, names: () => [...objects.keys()] };
}

export async function attestEnv(overrides: Partial<Env> = {}) {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const challenges = namespace((state) => new Challenges(state));
  const keys = namespace((state) => new AttestedKey(state));
  const counts = namespace((state) => new DailyCount(state));
  const perf = namespace((state) => new PerfReports(state));
  const env: Env = {
    SIGNING_KEY_JWK: JSON.stringify(await crypto.subtle.exportKey("jwk", pair.privateKey)),
    SIGNING_KID: "key-1",
    ALLOWED_ISSUERS: "https://bsky.social",
    DAILY_LIMIT: "2000",
    APPLE_TEAM_ID: TEAM,
    MIN_BUNDLE_VERSION: "0.1.0",
    RATE_LIMITER: { limit: async () => ({ success: true }) },
    DAILY_COUNT: counts.binding,
    CHALLENGES: challenges.binding,
    ATTESTED_KEYS: keys.binding,
    PERF_REPORTS: perf.binding,
    ASSETS: { fetch: async () => new Response("asset") },
    ...overrides,
  };
  return { env, challenges, keys, counts, perf };
}
