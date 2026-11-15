// App Attest receipts, as Apple documents them in "Assessing fraud risk": a
// PKCS #7 signed-data container whose payload is a SET of numbered fields.
// The attestation carries one ("ATTEST"); exchanging a receipt with Apple
// returns another ("RECEIPT") with the fraud metric. Apple sends the
// container in BER (indefinite lengths, its payload in chunks), so it has a
// reader of its own; the certificates and payload inside are DER.
// Every failure is a Refusal.

import { concat, equal, fromUtf8, refuse } from "./bytes.ts";
import { children, ecdsaSignatureToRaw, oid, OID, parseCertificate, readOnly, TAG, verifySignedBy, type Certificate } from "./der.ts";

/**
 * Apple Root CA - G3, from
 * https://www.apple.com/certificateauthority/AppleRootCA-G3.cer
 * (fetched 2026-11-13). P-384, valid 2014-04-30 to 2039-04-30.
 * SHA-256 fingerprint of the DER:
 * 63:34:3A:BF:B8:9A:6A:03:EB:B5:7E:9B:3F:5F:A7:BE:7C:4F:5C:75:6F:30:17:B3:A8:C4:88:C3:65:3E:91:79
 */
export const APPLE_ROOT_CA_G3 = `-----BEGIN CERTIFICATE-----
MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwS
QXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9u
IEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcN
MTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBS
b290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9y
aXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49
AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtf
TjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517
IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySr
MA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gA
MGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWTxnS4
at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM
6BgD56KyKA==
-----END CERTIFICATE-----`;

/**
 * Root CA G3 signs many Apple CAs, so the chain must also be the receipt
 * signer's: an intermediate marked as Apple's Application Integration CA,
 * and a signer marked for App Attest receipts (both seen on a real receipt).
 */
const INTEGRATION_CA_EXTENSION = "1.2.840.113635.100.6.2.3";
const RECEIPT_SIGNER_EXTENSION = "1.2.840.113635.100.12.15";

const SIGNED_DATA = "1.2.840.113549.1.7.2";
const DATA = "1.2.840.113549.1.7.1";
const SHA256 = "2.16.840.1.101.3.4.2.1";

/** How old a receipt may be when checked, and how far ahead of the Worker's clock. */
const RECEIPT_MAX_AGE_MS = 5 * 60 * 1000;
const CLOCK_SKEW_MS = 60 * 1000;

/** BER nesting the reader follows; Apple's receipts go five deep. */
const MAX_DEPTH = 12;

/** One BER element: its tag, its whole encoding, and its contents or children. */
interface Node {
  tag: number;
  encoded: Uint8Array;
  /** A primitive element's contents. */
  contents: Uint8Array;
  /** A constructed element's children. */
  children: Node[];
}

function readBer(bytes: Uint8Array, offset: number, depth: number): { node: Node; next: number } {
  if (depth > MAX_DEPTH) refuse("BER: too deep");
  if (offset + 2 > bytes.length) refuse("BER: truncated");
  const tag = bytes[offset];
  if ((tag & 0x1f) === 0x1f) refuse("BER: unsupported tag");
  const constructed = (tag & 0x20) !== 0;
  let length = bytes[offset + 1];
  let start = offset + 2;
  if (length === 0x80) {
    // An indefinite length: constructed children up to end-of-contents.
    if (!constructed) refuse("BER: indefinite primitive");
    const nodes: Node[] = [];
    let at = start;
    for (;;) {
      if (at + 2 > bytes.length) refuse("BER: truncated");
      if (bytes[at] === 0 && bytes[at + 1] === 0) break;
      const { node, next } = readBer(bytes, at, depth + 1);
      nodes.push(node);
      at = next;
    }
    const end = at + 2;
    return { node: { tag, encoded: bytes.subarray(offset, end), contents: new Uint8Array(), children: nodes }, next: end };
  }
  if (length & 0x80) {
    const width = length & 0x7f;
    if (width > 4) refuse("BER: unsupported length");
    if (start + width > bytes.length) refuse("BER: truncated");
    length = 0;
    for (let i = 0; i < width; i++) length = length * 256 + bytes[start + i];
    start += width;
  }
  const end = start + length;
  if (end > bytes.length) refuse("BER: truncated");
  const contents = bytes.subarray(start, end);
  const nodes: Node[] = [];
  if (constructed) {
    for (let at = 0; at < contents.length; ) {
      const { node, next } = readBer(contents, at, depth + 1);
      nodes.push(node);
      at = next;
    }
  }
  return { node: { tag, encoded: bytes.subarray(offset, end), contents: constructed ? new Uint8Array() : contents, children: nodes }, next: end };
}

function expect(node: Node | undefined, tag: number): Node {
  if (!node || node.tag !== tag) refuse("BER: unexpected tag");
  return node;
}

/** An OCTET STRING's bytes, joined from its chunks when it is constructed. */
function octets(node: Node | undefined): Uint8Array {
  if (node?.tag === TAG.OCTET_STRING) return node.contents;
  if (node?.tag === (TAG.OCTET_STRING | 0x20)) return concat(...node.children.map(octets));
  refuse("BER: unexpected tag");
}

/** An OID from a BER node, read with the DER reader: an OID is primitive, with a definite length. */
function oidOf(node: Node | undefined): string {
  return oid(readOnly(expect(node, TAG.OID).encoded, TAG.OID));
}

/** A small non-negative INTEGER, as receipts number their fields. */
function smallInteger(bytes: Uint8Array): number {
  if (bytes.length === 0 || bytes.length > 4 || bytes[0] & 0x80) refuse("receipt: bad integer");
  return bytes.reduce((value, byte) => value * 256 + byte, 0);
}

export interface ReceiptFields {
  /** Field 2: `<team ID>.<bundle ID>`. */
  appId: string;
  /** Field 3: the attested key's certificate, DER. */
  credCert: Uint8Array;
  /** Field 6: "ATTEST" or "RECEIPT". */
  type: string;
  /** Field 12, in milliseconds. */
  created: number;
  /** Field 17, a RECEIPT's count of keys attested on the device in 30 days. */
  riskMetric?: number;
  /** Field 19: a RECEIPT can't be exchanged before this, in milliseconds. */
  notBefore?: number;
  /** Field 21: Apple may not exchange it after this, in milliseconds. */
  expires?: number;
  /** Field 7, undocumented: the environment the key attested in, as seen on real receipts. */
  environment?: "production" | "development";
}

export interface ReceiptCheck {
  receipt: Uint8Array;
  /** The App ID the receipt must name. */
  appId: string;
  /** The attested key's certificate (the attestation's first x5c entry). */
  credCert: Uint8Array;
  type: "ATTEST" | "RECEIPT";
}

/**
 * Checks a receipt as Apple's "Verify the receipt" says: Apple signed it,
 * under Root CA G3 by the App Attest receipt signer; it names this app and
 * this key; it is the expected kind; and it is no more than five minutes old.
 * Returns its fields. `root` is Root CA G3 everywhere but the tests.
 */
/** The signed-data container's payload, certificates and signer infos, unverified. */
function openContainer(receipt: Uint8Array): { payload: Uint8Array; certificateSet: Node; signerInfos: Node[] } {
  const { node: contentInfo, next } = readBer(receipt, 0, 0);
  if (next !== receipt.length) refuse("BER: trailing bytes");
  const [contentType, wrapped] = expect(contentInfo, TAG.SEQUENCE).children;
  if (oidOf(contentType) !== SIGNED_DATA) refuse("receipt: not signed data");
  const signedData = expect(expect(wrapped, 0xa0).children[0], TAG.SEQUENCE).children;
  const [version, digests, encapsulated, ...rest] = signedData;
  expect(version, TAG.INTEGER);
  expect(digests, 0x31);
  const [eContentType, eContent] = expect(encapsulated, TAG.SEQUENCE).children;
  if (oidOf(eContentType) !== DATA) refuse("receipt: not data");
  const payload = octets(expect(eContent, 0xa0).children[0]);
  const certificateSet = rest.find((node) => node.tag === 0xa0);
  const signerInfos = expect(rest[rest.length - 1], 0x31).children;
  if (!certificateSet || signerInfos.length !== 1) refuse("receipt: signers");
  return { payload, certificateSet, signerInfos };
}

/**
 * The fields of a receipt the Worker verified when it stored it, read again
 * without checking anything: only for the Worker's own records.
 */
export function storedReceiptFields(receipt: Uint8Array): ReceiptFields {
  return readFields(openContainer(receipt).payload);
}

export async function verifyReceipt(input: ReceiptCheck, root: Uint8Array, now = Date.now()): Promise<ReceiptFields> {
  const { payload, certificateSet, signerInfos } = openContainer(input.receipt);

  // The one signer: no signed attributes, so it signs the payload itself.
  const [signerVersion, issuerAndSerial, digest, signatureAlgorithm, signature, ...unsigned] = expect(signerInfos[0], TAG.SEQUENCE).children;
  if (smallInteger(expect(signerVersion, TAG.INTEGER).contents) !== 1) refuse("receipt: signer version");
  if (oidOf(expect(digest, TAG.SEQUENCE).children[0]) !== SHA256) refuse("receipt: digest");
  if (oidOf(expect(signatureAlgorithm, TAG.SEQUENCE).children[0]) !== OID.ECDSA_SHA256) refuse("receipt: signature algorithm");
  if (unsigned.some((node) => node.tag !== 0xa1)) refuse("receipt: signer info");
  const [issuerName, serial] = expect(issuerAndSerial, TAG.SEQUENCE).children;

  // The chain: the signer, an intermediate that issued it, and the root.
  const certificates = certificateSet.children.map((node) => parseCertificate(expect(node, TAG.SEQUENCE).encoded));
  const signer = certificates.find((c) => equal(c.issuer, expect(issuerName, TAG.SEQUENCE).encoded) && equal(c.serial, expect(serial, TAG.INTEGER).contents));
  if (!signer) refuse("receipt: no signer certificate");
  const intermediate = certificates.find((c) => equal(c.subject, signer.issuer));
  if (!intermediate) refuse("receipt: no intermediate");
  const anchor = parseCertificate(root);
  for (const certificate of [anchor, intermediate, signer]) {
    if (now < certificate.notBefore || now > certificate.notAfter) refuse("receipt: certificate out of date");
  }
  await verifySignedBy(intermediate, anchor);
  await verifySignedBy(signer, intermediate);
  if (!intermediate.extensions.has(INTEGRATION_CA_EXTENSION) || !signer.extensions.has(RECEIPT_SIGNER_EXTENSION)) refuse("receipt: not a receipt signer");
  await verifyPayloadSignature(signer, octets(signature), payload);

  const fields = readFields(payload);
  if (fields.appId !== input.appId) refuse("receipt: app ID");
  if (!equal(fields.credCert, input.credCert)) refuse("receipt: key");
  if (fields.type !== input.type) refuse("receipt: type");
  if (fields.created > now + CLOCK_SKEW_MS || fields.created < now - RECEIPT_MAX_AGE_MS) refuse("receipt: not fresh");
  return fields;
}

async function verifyPayloadSignature(signer: Certificate, signature: Uint8Array, payload: Uint8Array): Promise<void> {
  const { algorithm, curve } = signer.publicKey;
  if (algorithm !== OID.EC_PUBLIC_KEY || curve !== OID.P256) refuse("receipt: signer key");
  const key = await crypto.subtle.importKey("spki", signer.publicKey.spki, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
  const raw = ecdsaSignatureToRaw(signature, 32);
  if (!(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, raw, payload))) refuse("receipt: signature");
}

/** The payload's numbered fields: a SET of SEQUENCE { type, version, value }. */
function readFields(payload: Uint8Array): ReceiptFields {
  const values = new Map<number, Uint8Array>();
  for (const field of children(readOnly(payload, 0x31))) {
    const [type, , value] = children(field, TAG.SEQUENCE);
    if (type?.tag !== TAG.INTEGER) refuse("receipt: bad field");
    const number = smallInteger(type.contents);
    if (values.has(number)) refuse("receipt: duplicate field");
    if (value?.tag !== TAG.OCTET_STRING) refuse("receipt: bad field");
    values.set(number, value.contents);
  }
  const text = (n: number) => {
    const value = values.get(n);
    if (value === undefined) refuse(`receipt: field ${n} missing`);
    return fromUtf8(value);
  };
  const date = (n: number) => {
    const value = Date.parse(text(n));
    if (!Number.isFinite(value)) refuse(`receipt: field ${n} not a date`);
    return value;
  };
  const credCert = values.get(3);
  if (!credCert) refuse("receipt: field 3 missing");
  const fields: ReceiptFields = { appId: text(2), credCert, type: text(6), created: date(12) };
  if (values.has(17)) {
    const metric = text(17);
    if (!/^\d{1,9}$/.test(metric)) refuse("receipt: field 17 not a number");
    fields.riskMetric = Number(metric);
  }
  if (values.has(19)) fields.notBefore = date(19);
  if (values.has(7)) {
    const environment = text(7);
    if (environment === "production" || environment === "development") fields.environment = environment;
  }
  if (values.has(21)) fields.expires = date(21);
  return fields;
}
