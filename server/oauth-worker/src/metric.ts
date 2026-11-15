// Apple's fraud metric for an attested key (ADR 0033, "Assessing fraud
// risk"): the Worker sends the attestation's receipt to Apple and gets back
// a new one carrying the number of keys the device has attested for Influx
// in the last 30 days. A high number suggests one compromised device minting
// keys for modified copies of the app.
//
// It needs a DeviceCheck key from the Apple Developer account, the
// APP_ATTEST_KEY secret: JSON {"keyId", "teamId", "p8"}. Without it nothing
// is asked of Apple.

import { base64url, fromBase64, toBase64, utf8 } from "./bytes.ts";

/** Apple's receipt exchange, by the environment the key attested in. */
export const ATTESTATION_DATA_URLS = {
  production: "https://data.appattest.apple.com/v1/attestationData",
  development: "https://data-development.appattest.apple.com/v1/attestationData",
} as const;

/** How long the Worker waits for Apple before registering without a metric. */
const EXCHANGE_TIMEOUT_MS = 5000;

export interface AppAttestKey {
  keyId: string;
  teamId: string;
  /** The PKCS #8 private key, PEM. */
  p8: string;
}

/** The configured key, or nothing when it is unset or malformed. */
export function appAttestKey(raw: string | undefined): AppAttestKey | undefined {
  if (!raw) return undefined;
  try {
    const value = JSON.parse(raw) as Partial<AppAttestKey>;
    const { keyId, teamId, p8 } = value;
    if (typeof keyId !== "string" || !/^[A-Z0-9]{10}$/.test(keyId)) return undefined;
    if (typeof teamId !== "string" || !/^[A-Z0-9]{10}$/.test(teamId)) return undefined;
    if (typeof p8 !== "string" || !p8.includes("BEGIN PRIVATE KEY")) return undefined;
    return { keyId, teamId, p8 };
  } catch {
    return undefined;
  }
}

/** The provider token Apple asks for, made as for APNs: ES256, `kid`, issued by the team. */
export async function providerToken(key: AppAttestKey, now = Date.now()): Promise<string> {
  const der = fromBase64(key.p8.replace(/-----(BEGIN|END) PRIVATE KEY-----/g, "").replace(/\s+/g, ""));
  const signer = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const part = (value: unknown) => base64url(utf8(JSON.stringify(value)));
  const unsigned = `${part({ alg: "ES256", kid: key.keyId })}.${part({ iss: key.teamId, iat: Math.floor(now / 1000) })}`;
  const signature = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, signer, utf8(unsigned)));
  return `${unsigned}.${base64url(signature)}`;
}

export type Exchange = { receipt: Uint8Array } | { failed: string };

/**
 * Sends `receipt` to Apple and returns the new one, or why there is none:
 * Apple's status, a malformed answer, or no answer in time. Never throws.
 */
export async function exchangeReceipt(
  key: AppAttestKey,
  receipt: Uint8Array,
  environment: "production" | "development",
  fetcher: typeof fetch = fetch,
): Promise<Exchange> {
  let token: string;
  try {
    token = await providerToken(key);
  } catch {
    return { failed: "key unusable" };
  }
  try {
    const response = await fetcher(ATTESTATION_DATA_URLS[environment], {
      method: "POST",
      headers: { Authorization: token },
      // Apple takes the receipt base64-encoded, and answers the same way.
      body: toBase64(receipt),
      signal: AbortSignal.timeout(EXCHANGE_TIMEOUT_MS),
    });
    if (response.status !== 200) return { failed: `Apple ${response.status}` };
    const text = (await response.text()).trim();
    const next = fromBase64(text);
    if (next.length === 0) return { failed: "empty answer" };
    return { receipt: next };
  } catch (caught) {
    return { failed: caught instanceof Error && caught.name === "TimeoutError" ? "timeout" : "unreachable or malformed" };
  }
}

/** A coarse band for a metric, for the day's usage counts. */
export function metricBand(metric: number | undefined): string {
  if (metric === undefined) return "none";
  if (metric <= 2) return String(metric);
  return metric <= 5 ? "3-5" : "6+";
}
