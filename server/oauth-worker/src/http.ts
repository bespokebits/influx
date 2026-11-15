// Response helpers shared by the routes and the Durable Objects.

export function json(status: number, value: unknown, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "Content-Type": "application/json", ...headers },
  });
}

export function error(status: number, code: string, headers: Record<string, string> = {}): Response {
  return json(status, { error: code }, headers);
}

/** Requests here are small; anything bigger is refused before it is parsed. */
export const MAX_BODY_BYTES = 16 * 1024;

/** The body's bytes, or nothing if it is too big. */
export async function bodyBytes(request: Request): Promise<Uint8Array | undefined> {
  const declared = Number(request.headers.get("Content-Length") ?? "0");
  if (declared > MAX_BODY_BYTES) return undefined;
  const bytes = new Uint8Array(await request.arrayBuffer());
  return bytes.length > MAX_BODY_BYTES ? undefined : bytes;
}

/** A JSON object from bytes, or nothing if they aren't one. */
export function jsonObject(bytes: Uint8Array): Record<string, unknown> | undefined {
  let value: unknown;
  try {
    value = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } catch {
    return undefined;
  }
  // JSON can be null, an array or a number; only an object has fields.
  return typeof value === "object" && value !== null && !Array.isArray(value) ? (value as Record<string, unknown>) : undefined;
}
