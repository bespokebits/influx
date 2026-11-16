// The Worker's Durable Objects, all SQLite-backed so they run on the Free
// plan. They keep a count from skipping, a challenge single-use and a key's
// counter rising.
//
// An object does not run its requests one at a time: another request can
// start at any await that isn't a storage call, such as reading a request's
// body. So each request reads its body first, and then does its
// read-compare-write as one step inside `blockConcurrencyWhile`, which lets
// no other request in until the step is done. That is chosen over
// `storage.transaction` because it holds the whole step, the clock reads and
// comparisons included, not just the storage calls, and the steps are a few
// storage calls long, so the hold is short.

import { json } from "./http.ts";

export interface Storage {
  get<T>(key: string): Promise<T | undefined>;
  put(key: string, value: unknown): Promise<void>;
  /** Up to 128 keys at once, all written or none. */
  put(entries: Record<string, unknown>): Promise<void>;
  delete(key: string | string[]): Promise<unknown>;
  /** In key order; `start` is inclusive, `end` exclusive, as in a Durable Object. */
  list<T>(options?: { start?: string; end?: string }): Promise<Map<string, T>>;
  /** The time the object's alarm is set for, in ms since 1970, or null. */
  getAlarm(): Promise<number | null>;
  /** Sets the object's one alarm, replacing any other; `alarm()` runs then. */
  setAlarm(time: number): Promise<void>;
}

export interface State {
  storage: Storage;
  /** Runs `callback` with no other request let in until it is done. */
  blockConcurrencyWhile<T>(callback: () => Promise<T>): Promise<T>;
}

/** A Durable Object namespace binding, as far as the Worker uses it. */
export interface Namespace {
  idFromName(name: string): unknown;
  get(id: unknown): { fetch(request: Request): Promise<Response> };
}

/** Whether a signed assertion came from an attested caller. */
export type Kind = "attested" | "unattested";

const empty = (status: number) => new Response(null, { status });

/** A request's JSON body, read before any state is touched; nothing if it isn't JSON. */
async function body<T>(request: Request): Promise<T | undefined> {
  try {
    return (await request.json()) as T;
  } catch {
    return undefined;
  }
}

/** The longest event name `DailyCount` keeps; longer ones are cut. */
const EVENT_NAME_LENGTH = 80;

/**
 * The day's assertion count, one object for the whole Worker. Keys are UTC
 * dates, with the attested and unattested counts beside each, and the day's
 * attestation events: challenges issued, registrations, and each refusal by
 * the check that failed. Event names are fixed strings from the Worker,
 * never anything a caller sent.
 */
export class DailyCount {
  private readonly state: State;

  constructor(state: State, _env?: unknown) {
    this.state = state;
  }

  /**
   * GET reads today's counts; POST takes one, up to `?limit=`, of `?kind=`;
   * POST `?event=` counts one event and nothing else.
   */
  async fetch(request: Request): Promise<Response> {
    const params = new URL(request.url).searchParams;
    const limit = Number.parseInt(params.get("limit") ?? "", 10);
    const kind = params.get("kind");
    const event = params.get("event");
    const storage = this.state.storage;
    return this.state.blockConcurrencyWhile(async () => {
      const today = new Date().toISOString().slice(0, 10);
      const count = (await storage.get<number>(today)) ?? 0;
      const eventPrefix = `${today} event `;
      if (request.method === "GET") {
        const attested = (await storage.get<number>(`${today} attested`)) ?? 0;
        const unattested = (await storage.get<number>(`${today} unattested`)) ?? 0;
        const events = Object.fromEntries(
          [...(await storage.list<number>()).entries()].filter(([key]) => key.startsWith(eventPrefix)).map(([key, value]) => [key.slice(eventPrefix.length), value]),
        );
        return json(200, { day: today, count, attested, unattested, events });
      }
      // A new day: forget the old ones.
      const forgetOldDays = async () => {
        const old = [...(await storage.list<number>()).keys()].filter((key) => !key.startsWith(today));
        if (old.length > 0) await storage.delete(old);
      };
      if (event) {
        const key = `${eventPrefix}${event.slice(0, EVENT_NAME_LENGTH)}`;
        const seen = await storage.get<number>(key);
        if (seen === undefined) await forgetOldDays();
        await storage.put(key, (seen ?? 0) + 1);
        return empty(204);
      }
      if (!(limit > 0) || count >= limit) return empty(429);
      if (count === 0) await forgetOldDays();
      await storage.put(today, count + 1);
      if (kind === "attested" || kind === "unattested") {
        const key = `${today} ${kind}`;
        await storage.put(key, ((await storage.get<number>(key)) ?? 0) + 1);
      }
      return empty(204);
    });
  }
}

/** How long a challenge is good for. */
export const CHALLENGE_LIFETIME_MS = 5 * 60 * 1000;

/**
 * Outstanding challenges, for registrations and attested assertion
 * requests alike, one object for the whole Worker. Each is stored under its
 * own value with its expiry, and a consume removes it whether or not it was
 * still good.
 */
export class Challenges {
  private readonly state: State;
  private lastSweep = 0;

  constructor(state: State, _env?: unknown) {
    this.state = state;
  }

  /** POST `/issue?c=` stores one; POST `/consume?c=` takes it: 204 if good, 404 if not. */
  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const challenge = url.searchParams.get("c");
    if (request.method !== "POST" || !challenge) return empty(400);
    const storage = this.state.storage;
    if (url.pathname === "/issue") {
      return this.state.blockConcurrencyWhile(async () => {
        const now = Date.now();
        await this.sweep(now);
        await storage.put(challenge, now + CHALLENGE_LIFETIME_MS);
        return empty(204);
      });
    }
    if (url.pathname === "/consume") {
      // The read and the delete are one step, so two requests can't both
      // find the challenge before either removes it.
      return this.state.blockConcurrencyWhile(async () => {
        const expires = await storage.get<number>(challenge);
        if (expires === undefined) return empty(404);
        await storage.delete(challenge);
        return empty(Date.now() <= expires ? 204 : 404);
      });
    }
    return empty(404);
  }

  /** At most once a minute, drops challenges nobody used. Called inside a step. */
  private async sweep(now: number): Promise<void> {
    if (now - this.lastSweep < 60_000) return;
    this.lastSweep = now;
    const expired = [...(await this.state.storage.list<number>()).entries()].filter(([, expires]) => expires < now).map(([key]) => key);
    if (expired.length > 0) await this.state.storage.delete(expired);
  }
}

/**
 * The registration checks a key passed, raised when they tighten. 1: the
 * Mac's policy check follows the OS its certificate names. Once attestation
 * is required, a key registered under older checks must register again.
 */
export const REGISTRATION_CHECKS = 1;

/** How often a key without a fraud metric may ask Apple again. */
export const METRIC_RETRY_MS = 24 * 60 * 60 * 1000;

/** A key unused this long is forgotten; its install registers again. */
export const KEY_IDLE_LIMIT_MS = 90 * 24 * 60 * 60 * 1000;

export interface KeyRecord {
  /** The 65-byte uncompressed P-256 point, base64. */
  publicKey: string;
  /** The last assertion counter accepted; 0 when registered. */
  counter: number;
  platform: "ios" | "mac";
  /** The bundle ID it attested for. */
  appId: string;
  /** The team ID its App ID was checked with, so its assertions are too. */
  teamId: string;
  /** For the record: the launch category (2 TestFlight, 3 development, 4 App Store) last attested. */
  category: number;
  /** For the record: the app's bundle version last attested, when it had one. */
  bundleVersion?: string;
  /** The key's certificate from its attestation, base64 DER: public, and what its receipts name. */
  credCert?: string;
  /**
   * The key's newest App Attest receipt, base64: the attestation's, or the
   * one Apple returned with the fraud metric, which a later check exchanges.
   */
  receipt: string;
  /** Apple's fraud metric: keys the device attested for Influx in 30 days. */
  riskMetric?: number;
  /** When the Worker last asked Apple for the metric. */
  metricCheckedAt?: number;
  /** The environment the key attested in, which its receipts belong to. */
  environment?: "production" | "development";
  /** The OS family its certificate names ("macosx"), when it names one. */
  os?: string;
  /** The REGISTRATION_CHECKS it passed; none before they were counted. */
  checks?: number;
  registeredAt: number;
  lastUsed: number;
}

/**
 * One attested key, in an object named by its key ID. Each request's
 * read-compare-write is one step, so the counter only ever rises and each
 * value is accepted once.
 */
export class AttestedKey {
  private readonly state: State;

  constructor(state: State, _env?: unknown) {
    this.state = state;
  }

  /**
   * GET reads the key (404 if unknown or idle too long). PUT registers it,
   * keeping the counter of one already registered. POST `/advance` with
   * `{"counter", "category", "bundleVersion"}` accepts a higher counter
   * (204), noting the launch context with it, or refuses (409). POST
   * `/metric-claim` claims the day's fraud-metric check for a key without a
   * metric (204), or says one isn't due (409), in one step, so concurrent
   * requests ask Apple once. POST `/metric` with `{"metricCheckedAt",
   * "receipt"?, "riskMetric"?}` records a check's result (204). Neither
   * touches the counter.
   */
  async fetch(request: Request): Promise<Response> {
    const path = new URL(request.url).pathname;
    const advancing = request.method === "POST" && path === "/advance";
    const metric = request.method === "POST" && path === "/metric";
    const claim = request.method === "POST" && path === "/metric-claim";
    if (request.method !== "GET" && request.method !== "PUT" && !advancing && !metric && !claim) return empty(400);
    // The body first: reading it is an await that would let another request in.
    const sent = request.method === "GET" ? {} : await body<Partial<KeyRecord>>(request);
    if (!sent) return empty(400);

    return this.state.blockConcurrencyWhile(async () => {
      const now = Date.now();
      const record = await this.current(now);
      if (request.method === "GET") return record ? json(200, record) : empty(404);
      if (request.method === "PUT") {
        if (record) {
          // Registering again (a retry after a lost answer) must not reset
          // the counter, or old assertions would count again.
          return empty(record.publicKey === sent.publicKey ? 200 : 409);
        }
        await this.state.storage.put("key", { ...sent, counter: 0, registeredAt: now, lastUsed: now });
        return empty(201);
      }
      if (!record) return empty(404);
      if (claim) {
        const due = record.riskMetric === undefined && (record.metricCheckedAt === undefined || now - record.metricCheckedAt >= METRIC_RETRY_MS);
        if (!due) return empty(409);
        await this.state.storage.put("key", { ...record, metricCheckedAt: now });
        return empty(204);
      }
      if (metric) {
        const { metricCheckedAt, receipt, riskMetric } = sent;
        if (typeof metricCheckedAt !== "number") return empty(400);
        if (receipt !== undefined && typeof receipt !== "string") return empty(400);
        if (riskMetric !== undefined && (typeof riskMetric !== "number" || !Number.isSafeInteger(riskMetric))) return empty(400);
        await this.state.storage.put("key", {
          ...record,
          metricCheckedAt,
          ...(receipt ? { receipt } : {}),
          ...(riskMetric === undefined ? {} : { riskMetric }),
        });
        return empty(204);
      }
      const { counter, category, bundleVersion } = sent;
      if (typeof counter !== "number" || !Number.isSafeInteger(counter) || counter <= record.counter) return empty(409);
      await this.state.storage.put("key", {
        ...record,
        counter,
        category: category ?? record.category,
        bundleVersion: bundleVersion ?? record.bundleVersion,
        lastUsed: now,
      });
      return empty(204);
    });
  }

  /** The stored key, after forgetting it if it has been idle too long. Called inside a step. */
  private async current(now: number): Promise<KeyRecord | undefined> {
    const record = await this.state.storage.get<KeyRecord>("key");
    if (record && now - record.lastUsed > KEY_IDLE_LIMIT_MS) {
      await this.state.storage.delete("key");
      return undefined;
    }
    return record;
  }
}

/** The most field performance reports kept for one UTC day (ADR 0034). */
export const PERF_DAILY_LIMIT = 200;
/** How many UTC days of reports are kept, today included. */
export const PERF_RETENTION_DAYS = 90;
const DAY_MS = 24 * 60 * 60 * 1000;
/** The most keys a Durable Object's storage deletes in one call. */
export const DELETE_BATCH = 128;

/** The UTC date `days` before `now`, as `YYYY-MM-DD`. */
function utcDay(now: number, days = 0): string {
  return new Date(now - days * DAY_MS).toISOString().slice(0, 10);
}

/** A minute into the next UTC day after `now`, in ms since 1970. */
function nextDayStart(now: number): number {
  return (Math.floor(now / DAY_MS) + 1) * DAY_MS + 60_000;
}

/** A day's stored reports, oldest first. */
type StoredDay = Record<string, unknown>[];

/**
 * Field performance reports (ADR 0034), one object for the Worker, one
 * record per UTC day under its date: the day's reports, in the order they
 * came, each with the time it came. The route checks a report before it
 * gets here. At most 200 a day, which keeps a day's record well under a
 * stored value's limit. The days before the last 90 go when a new day's
 * first report arrives, and also at an alarm early each UTC day while any
 * report is kept, so they go on time even when reports stop coming.
 *
 * Each report carries a random ID the app made for it. An app whose answer
 * was lost sends it again, so each one taken is noted under `seen:<ID>`
 * with its day, and a report seen already is answered as stored without
 * being kept twice.
 */
export class PerfReports {
  private readonly state: State;

  constructor(state: State, _env?: unknown) {
    this.state = state;
  }

  /**
   * POST `/add` with a report stores it (204), or refuses it once today has
   * its 200 (429); one seen already is 204 and stored once. GET `/?days=N`
   * reads the last N days' reports, newest first, and changes nothing.
   */
  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const storage = this.state.storage;
    if (request.method === "GET") {
      const days = Number.parseInt(url.searchParams.get("days") ?? "", 10);
      if (!(days >= 1 && days <= PERF_RETENTION_DAYS)) return empty(400);
      const now = Date.now();
      // Older days not yet removed are never read, nor the `seen:` names,
      // which sort after every date.
      const stored = await storage.list<StoredDay>({ start: utcDay(now, days - 1), end: `${utcDay(now)}~` });
      const reports = [...stored.keys()].sort().reverse().flatMap((day) => [...(stored.get(day) ?? [])].reverse());
      return json(200, { reports });
    }
    if (request.method !== "POST" || url.pathname !== "/add") return empty(400);
    // The body first: reading it is an await that would let another request in.
    const report = await body<Record<string, unknown>>(request);
    if (!report) return empty(400);
    const name = `seen:${report.id}`;
    return this.state.blockConcurrencyWhile(async () => {
      const now = Date.now();
      const today = utcDay(now);
      if ((await storage.get<string>(name)) !== undefined) return empty(204);
      const reports = (await storage.get<StoredDay>(today)) ?? [];
      if (reports.length >= PERF_DAILY_LIMIT) return empty(429);
      if (reports.length === 0) await this.expire(now);
      // The report and its name in one write, so a failure part way can't
      // keep the report without the name that stops it being kept twice.
      await storage.put({ [today]: [...reports, { ...report, receivedAt: new Date(now).toISOString() }], [name]: today });
      if ((await storage.getAlarm()) === null) await storage.setAlarm(nextDayStart(now));
      return empty(204);
    });
  }

  /** The daily alarm: removes expired days, and comes again tomorrow while
   *  anything is still kept. */
  async alarm(): Promise<void> {
    await this.state.blockConcurrencyWhile(async () => {
      const now = Date.now();
      await this.expire(now);
      if ((await this.state.storage.list()).size > 0) await this.state.storage.setAlarm(nextDayStart(now));
    });
  }

  /** Removes the days before the last 90, and the names of their reports. */
  private async expire(now: number): Promise<void> {
    const storage = this.state.storage;
    const cutoff = utcDay(now, PERF_RETENTION_DAYS - 1);
    const oldDays = [...(await storage.list({ end: cutoff })).keys()];
    const oldNames = [...(await storage.list<string>({ start: "seen:", end: "seen;" })).entries()].filter(([, day]) => day < cutoff).map(([key]) => key);
    const old = [...oldDays, ...oldNames];
    // A Durable Object deletes at most 128 keys a call.
    for (let start = 0; start < old.length; start += DELETE_BATCH) await storage.delete(old.slice(start, start + DELETE_BATCH));
  }
}
