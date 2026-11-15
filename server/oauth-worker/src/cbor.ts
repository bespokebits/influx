// A minimal CBOR (RFC 8949) decoder for App Attest's attestation and
// assertion objects. It reads only what those use: unsigned and negative
// integers, byte and text strings, arrays, maps and the simple values false,
// true and null. Anything else, including indefinite lengths, tags and
// floats, is a refusal, as is any byte left over.

import { fromUtf8, refuse } from "./bytes.ts";

export type CborValue = number | string | boolean | null | Uint8Array | CborValue[] | Map<string | number, CborValue>;

/** Deep enough for App Attest's objects, shallow enough to bound recursion. */
const MAX_DEPTH = 8;

export function decodeCbor(bytes: Uint8Array): CborValue {
  const { value, next } = decodeCborItem(bytes, 0);
  if (next !== bytes.length) refuse("CBOR: trailing bytes");
  return value;
}

/**
 * One item starting at `offset`, and where it ends, for CBOR that is
 * followed by more bytes (authenticator data's key and extensions).
 */
export function decodeCborItem(bytes: Uint8Array, offset: number): { value: CborValue; next: number } {
  if (!Number.isSafeInteger(offset) || offset < 0 || offset > bytes.length) refuse("CBOR: bad offset");
  const reader = { bytes, offset };
  const value = item(reader, 0);
  return { value, next: reader.offset };
}

interface Reader {
  bytes: Uint8Array;
  offset: number;
}

function take(reader: Reader, count: number): Uint8Array {
  if (count < 0 || reader.offset + count > reader.bytes.length) refuse("CBOR: truncated");
  const out = reader.bytes.subarray(reader.offset, reader.offset + count);
  reader.offset += count;
  return out;
}

/** The argument after an initial byte's additional information. */
function argument(reader: Reader, info: number): number {
  if (info < 24) return info;
  const width = info === 24 ? 1 : info === 25 ? 2 : info === 26 ? 4 : info === 27 ? 8 : 0;
  // 28 to 30 are reserved, and 31 is an indefinite length.
  if (width === 0) refuse("CBOR: unsupported length");
  let value = 0;
  for (const byte of take(reader, width)) value = value * 256 + byte;
  if (!Number.isSafeInteger(value)) refuse("CBOR: integer too large");
  return value;
}

function item(reader: Reader, depth: number): CborValue {
  if (depth > MAX_DEPTH) refuse("CBOR: too deep");
  const [initial] = take(reader, 1);
  const major = initial >> 5;
  const info = initial & 0x1f;
  if (major === 7) {
    if (info === 20) return false;
    if (info === 21) return true;
    if (info === 22) return null;
    refuse("CBOR: unsupported simple value");
  }
  if (major === 6) refuse("CBOR: tags are not supported");
  const value = argument(reader, info);
  switch (major) {
    case 0:
      return value;
    case 1:
      return -1 - value;
    case 2:
      return take(reader, value).slice();
    case 3:
      return fromUtf8(take(reader, value));
    case 4: {
      // Every item is at least one byte, so a longer count is a lie.
      if (value > reader.bytes.length - reader.offset) refuse("CBOR: truncated");
      const array: CborValue[] = [];
      for (let i = 0; i < value; i++) array.push(item(reader, depth + 1));
      return array;
    }
    default: {
      if (value * 2 > reader.bytes.length - reader.offset) refuse("CBOR: truncated");
      const map = new Map<string | number, CborValue>();
      for (let i = 0; i < value; i++) {
        const key = item(reader, depth + 1);
        if (typeof key !== "string" && typeof key !== "number") refuse("CBOR: unsupported map key");
        if (map.has(key)) refuse("CBOR: duplicate map key");
        map.set(key, item(reader, depth + 1));
      }
      return map;
    }
  }
}
