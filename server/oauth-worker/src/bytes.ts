// Byte helpers shared by the parsers and the attestation checks.

/**
 * A request the Worker refuses. The message says which check, for tests and
 * logs; callers answer with a fixed error code and never show it.
 *
 * "invalid" is malformed or unproven input, which a new key or a retry may
 * fix. "policy" is a genuine app the Worker doesn't accept (its version,
 * how it was signed, its key's access policy, its app ID), which only a
 * different build can fix.
 */
export class Refusal extends Error {
  readonly kind: "invalid" | "policy";

  constructor(message: string, kind: "invalid" | "policy" = "invalid") {
    super(message);
    this.kind = kind;
  }
}

export function refuse(reason: string): never {
  throw new Refusal(reason);
}

/** Refuses a genuine app the Worker doesn't accept. */
export function refusePolicy(reason: string): never {
  throw new Refusal(reason, "policy");
}

export function utf8(text: string): Uint8Array {
  return new TextEncoder().encode(text);
}

/** Strict UTF-8: a bad byte is a refusal, not a replacement character. */
export function fromUtf8(bytes: Uint8Array): string {
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    refuse("invalid UTF-8");
  }
}

export function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((total, part) => total + part.length, 0));
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

export function equal(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let difference = 0;
  for (let i = 0; i < a.length; i++) difference |= a[i] ^ b[i];
  return difference === 0;
}

export async function sha256(bytes: Uint8Array): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
}

/**
 * Standard or URL-safe base64, padded or not. Anything else (whitespace,
 * mixed alphabets, a bad length) is a refusal.
 */
export function fromBase64(text: string): Uint8Array {
  if (!/^[A-Za-z0-9+/]*={0,2}$/.test(text) && !/^[A-Za-z0-9_-]*$/.test(text)) refuse("invalid base64");
  const bare = text.replace(/=+$/, "").replaceAll("-", "+").replaceAll("_", "/");
  if (bare.length % 4 === 1) refuse("invalid base64");
  if (text.includes("=") && text.length % 4 !== 0) refuse("invalid base64");
  let binary: string;
  try {
    binary = atob(bare + "=".repeat((4 - (bare.length % 4)) % 4));
  } catch {
    refuse("invalid base64");
  }
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

export function toBase64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

export function base64url(bytes: Uint8Array): string {
  return toBase64(bytes).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}
