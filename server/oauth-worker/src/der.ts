// A minimal DER reader, and the parts of an X.509 certificate the App Attest
// checks need. It checks every length against the bytes it has and refuses
// what DER forbids (indefinite and non-minimal lengths), so a malformed
// certificate is a refusal, never a crash.

import { equal, refuse } from "./bytes.ts";

export const TAG = {
  BOOLEAN: 0x01,
  INTEGER: 0x02,
  BIT_STRING: 0x03,
  OCTET_STRING: 0x04,
  OID: 0x06,
  UTC_TIME: 0x17,
  GENERALIZED_TIME: 0x18,
  SEQUENCE: 0x30,
} as const;

/** One DER element: its tag, its whole encoding and its contents. */
export interface Element {
  tag: number;
  /** The whole element, tag and length included. */
  encoded: Uint8Array;
  contents: Uint8Array;
}

/** Reads the element at `offset`, and where the next one starts. */
export function readElement(bytes: Uint8Array, offset = 0): { element: Element; next: number } {
  if (offset + 2 > bytes.length) refuse("DER: truncated");
  const tag = bytes[offset];
  // Tag numbers of 31 and up take more bytes; nothing here uses them.
  if ((tag & 0x1f) === 0x1f) refuse("DER: unsupported tag");
  let length = bytes[offset + 1];
  let start = offset + 2;
  if (length & 0x80) {
    const width = length & 0x7f;
    // 0x80 is an indefinite length, which DER forbids.
    if (width === 0 || width > 4) refuse("DER: unsupported length");
    if (start + width > bytes.length) refuse("DER: truncated");
    length = 0;
    for (let i = 0; i < width; i++) length = length * 256 + bytes[start + i];
    if (bytes[start] === 0 || length < 0x80) refuse("DER: non-minimal length");
    start += width;
  }
  const end = start + length;
  if (end > bytes.length) refuse("DER: truncated");
  return {
    element: { tag, encoded: bytes.subarray(offset, end), contents: bytes.subarray(start, end) },
    next: end,
  };
}

/** Exactly one element filling `bytes`. */
export function readOnly(bytes: Uint8Array, tag?: number): Element {
  const { element, next } = readElement(bytes);
  if (next !== bytes.length) refuse("DER: trailing bytes");
  if (tag !== undefined && element.tag !== tag) refuse("DER: unexpected tag");
  return element;
}

/** A constructed element's children, in order. */
export function children(element: Element, tag?: number): Element[] {
  if (!(element.tag & 0x20)) refuse("DER: not constructed");
  if (tag !== undefined && element.tag !== tag) refuse("DER: unexpected tag");
  const out: Element[] = [];
  let offset = 0;
  while (offset < element.contents.length) {
    const { element: child, next } = readElement(element.contents, offset);
    out.push(child);
    offset = next;
  }
  return out;
}

function expect(element: Element | undefined, tag: number): Element {
  if (!element || element.tag !== tag) refuse("DER: unexpected tag");
  return element;
}

/** An OBJECT IDENTIFIER as dotted decimal. */
export function oid(element: Element): string {
  const bytes = expect(element, TAG.OID).contents;
  if (bytes.length === 0 || bytes[bytes.length - 1] & 0x80) refuse("DER: bad OID");
  const parts: number[] = [];
  let value = 0;
  for (let i = 0; i < bytes.length; i++) {
    // A leading 0x80 would pad the number, which DER forbids.
    if (value === 0 && bytes[i] === 0x80) refuse("DER: bad OID");
    value = value * 128 + (bytes[i] & 0x7f);
    if (value > Number.MAX_SAFE_INTEGER / 128) refuse("DER: bad OID");
    if (!(bytes[i] & 0x80)) {
      if (parts.length === 0) parts.push(value < 80 ? Math.floor(value / 40) : 2, value < 80 ? value % 40 : value - 80);
      else parts.push(value);
      value = 0;
    }
  }
  return parts.join(".");
}

/** A BIT STRING's bytes; only whole bytes, as keys and signatures are. */
export function bitString(element: Element): Uint8Array {
  const bytes = expect(element, TAG.BIT_STRING).contents;
  if (bytes.length === 0 || bytes[0] !== 0) refuse("DER: bad bit string");
  return bytes.subarray(1);
}

/** A UTCTime or GeneralizedTime in UTC, in milliseconds since the epoch. */
export function time(element: Element): number {
  if (element.contents.length > 15) refuse("DER: bad time");
  const text = String.fromCharCode(...element.contents);
  let match: RegExpMatchArray | null;
  let year: number;
  if (element.tag === TAG.UTC_TIME) {
    match = text.match(/^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/);
    if (!match) refuse("DER: bad time");
    // RFC 5280: two-digit years from 50 are 19xx, below 50 are 20xx.
    year = Number(match[1]) + (Number(match[1]) >= 50 ? 1900 : 2000);
  } else if (element.tag === TAG.GENERALIZED_TIME) {
    match = text.match(/^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/);
    if (!match) refuse("DER: bad time");
    year = Number(match[1]);
  } else {
    refuse("DER: bad time");
  }
  const [month, day, hour, minute, second] = match.slice(2).map(Number);
  const value = Date.UTC(year, month - 1, day, hour, minute, second);
  const check = new Date(value);
  // Date.UTC rolls 31 February into March; a real time round-trips.
  if (check.getUTCMonth() !== month - 1 || check.getUTCDate() !== day || hour > 23 || minute > 59 || second > 59) {
    refuse("DER: bad time");
  }
  return value;
}

export const OID = {
  EC_PUBLIC_KEY: "1.2.840.10045.2.1",
  P256: "1.2.840.10045.3.1.7",
  P384: "1.3.132.0.34",
  ECDSA_SHA256: "1.2.840.10045.4.3.2",
  ECDSA_SHA384: "1.2.840.10045.4.3.3",
} as const;

export interface PublicKeyInfo {
  /** The whole SubjectPublicKeyInfo, as WebCrypto imports it. */
  spki: Uint8Array;
  algorithm: string;
  /** The named curve, for an EC key. */
  curve?: string;
  /** The key itself: for an EC key, the uncompressed point. */
  key: Uint8Array;
}

export function publicKeyInfo(element: Element): PublicKeyInfo {
  const [algorithm, key] = children(element, TAG.SEQUENCE);
  const [algorithmId, parameters] = children(expect(algorithm, TAG.SEQUENCE));
  const info: PublicKeyInfo = { spki: element.encoded, algorithm: oid(algorithmId), key: bitString(key) };
  if (parameters?.tag === TAG.OID) info.curve = oid(parameters);
  return info;
}

export interface Certificate {
  /** The signed part, exactly as signed. */
  tbs: Uint8Array;
  /** The serial number's INTEGER contents. */
  serial: Uint8Array;
  signatureAlgorithm: string;
  signature: Uint8Array;
  issuer: Uint8Array;
  subject: Uint8Array;
  notBefore: number;
  notAfter: number;
  publicKey: PublicKeyInfo;
  /** Extension values (the OCTET STRING's contents) by OID. */
  extensions: Map<string, Uint8Array>;
}

export function parseCertificate(der: Uint8Array): Certificate {
  const [tbs, algorithm, signature, ...rest] = children(readOnly(der), TAG.SEQUENCE);
  if (rest.length > 0) refuse("DER: bad certificate");
  const signatureAlgorithm = oid(children(expect(algorithm, TAG.SEQUENCE))[0]);
  const fields = children(expect(tbs, TAG.SEQUENCE));
  let index = 0;
  if (fields[index]?.tag === 0xa0) index++; // [0] version
  const serial = expect(fields[index++], TAG.INTEGER).contents;
  const innerAlgorithm = oid(children(expect(fields[index++], TAG.SEQUENCE))[0]);
  // The signed copy of the algorithm must match the one outside, or the
  // outer one could be swapped.
  if (innerAlgorithm !== signatureAlgorithm) refuse("certificate: algorithm mismatch");
  const issuer = expect(fields[index++], TAG.SEQUENCE).encoded;
  const [notBefore, notAfter] = children(expect(fields[index++], TAG.SEQUENCE));
  if (!notBefore || !notAfter) refuse("DER: bad validity");
  const subject = expect(fields[index++], TAG.SEQUENCE).encoded;
  const publicKey = publicKeyInfo(expect(fields[index++], TAG.SEQUENCE));
  const extensions = new Map<string, Uint8Array>();
  for (const field of fields.slice(index)) {
    // [1] and [2] are unique IDs, which Apple's certificates don't use.
    if (field.tag !== 0xa3) continue;
    for (const extension of children(readOnly(field.contents, TAG.SEQUENCE))) {
      const parts = children(expect(extension, TAG.SEQUENCE));
      const id = oid(parts[0]);
      const value = expect(parts[parts.length - 1], TAG.OCTET_STRING).contents;
      if (parts.length === 3) expect(parts[1], TAG.BOOLEAN);
      else if (parts.length !== 2) refuse("DER: bad extension");
      if (extensions.has(id)) refuse("certificate: duplicate extension");
      extensions.set(id, value);
    }
  }
  return {
    tbs: tbs.encoded,
    serial,
    signatureAlgorithm,
    signature: bitString(signature),
    issuer,
    subject,
    notBefore: time(notBefore),
    notAfter: time(notAfter),
    publicKey,
    extensions,
  };
}

/** A DER ECDSA signature as the r || s WebCrypto wants, each `size` bytes. */
export function ecdsaSignatureToRaw(der: Uint8Array, size: number): Uint8Array {
  const parts = children(readOnly(der), TAG.SEQUENCE);
  if (parts.length !== 2) refuse("DER: bad signature");
  const raw = new Uint8Array(size * 2);
  parts.forEach((part, i) => {
    let value = expect(part, TAG.INTEGER).contents;
    // r and s are positive, so a set sign bit is malformed, and one leading
    // zero may be there to keep it clear.
    if (value.length === 0 || value[0] & 0x80) refuse("DER: bad signature");
    if (value.length > 1 && value[0] === 0) value = value.subarray(1);
    if (value.length > size) refuse("DER: bad signature");
    raw.set(value, i * size + size - value.length);
  });
  return raw;
}

const CURVES: Record<string, { name: string; size: number }> = {
  [OID.P256]: { name: "P-256", size: 32 },
  [OID.P384]: { name: "P-384", size: 48 },
};

const HASHES: Record<string, string> = {
  [OID.ECDSA_SHA256]: "SHA-256",
  [OID.ECDSA_SHA384]: "SHA-384",
};

/** That `issuer` named and signed `certificate`, with the algorithm the certificate states. */
export async function verifySignedBy(certificate: Certificate, issuer: Certificate): Promise<void> {
  const hash = HASHES[certificate.signatureAlgorithm];
  if (!hash) refuse("chain: unsupported signature algorithm");
  const curve = issuer.publicKey.algorithm === OID.EC_PUBLIC_KEY ? CURVES[issuer.publicKey.curve ?? ""] : undefined;
  if (!curve) refuse("chain: unsupported issuer key");
  if (!equal(certificate.issuer, issuer.subject)) refuse("chain: issuer name");
  const key = await crypto.subtle.importKey("spki", issuer.publicKey.spki, { name: "ECDSA", namedCurve: curve.name }, false, ["verify"]);
  const signature = ecdsaSignatureToRaw(certificate.signature, curve.size);
  if (!(await crypto.subtle.verify({ name: "ECDSA", hash }, key, signature, certificate.tbs))) refuse("chain: signature");
}
