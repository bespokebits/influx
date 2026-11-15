// The Durable Objects under concurrent requests. A real object lets another
// request in at any await that isn't a storage call, so every
// read-compare-write must be one step. The stand-in storage yields on every
// call, so a step that isn't atomic loses these races.
import { test } from "node:test";
import assert from "node:assert/strict";
import { AttestedKey, Challenges, DailyCount } from "../src/objects.ts";
import { memoryState, memoryStorage } from "./helpers.ts";

const RECORD = {
  publicKey: "BA==",
  counter: 0,
  platform: "ios",
  appId: "dev.bespokebits.influx",
  teamId: "TEAMID1234",
  category: 2,
  bundleVersion: "0.1.0",
  receipt: "AQID",
};

const put = (key: AttestedKey, publicKey = RECORD.publicKey) =>
  key.fetch(new Request("https://key/", { method: "PUT", body: JSON.stringify({ ...RECORD, publicKey }) }));
const advance = (key: AttestedKey, counter: number) =>
  key.fetch(new Request("https://key/advance", { method: "POST", body: JSON.stringify({ counter }) }));

async function registeredKey() {
  const state = memoryState();
  const key = new AttestedKey(state);
  assert.equal((await put(key)).status, 201);
  return { key, storage: state.storage };
}

function statuses(responses: Response[]): number[] {
  return responses.map((response) => response.status).sort();
}

test("two concurrent advances with the same counter: exactly one is accepted", async () => {
  const { key, storage } = await registeredKey();
  assert.deepEqual(statuses(await Promise.all([advance(key, 1), advance(key, 1)])), [204, 409]);
  assert.equal((storage.map.get("key") as { counter: number }).counter, 1);
});

test("concurrent advances in either order end at the higher counter, never moving back", async () => {
  for (const [first, second] of [[5, 3], [3, 5]]) {
    const { key, storage } = await registeredKey();
    await Promise.all([advance(key, first), advance(key, second)]);
    assert.equal((storage.map.get("key") as { counter: number }).counter, 5, `${first} then ${second}`);
    const counters = storage.writes.filter(([name]) => name === "key").map(([, value]) => (value as { counter: number }).counter);
    assert.deepEqual(counters, [...counters].sort((a, b) => a - b), `${first} then ${second}: ${counters}`);
  }
});

test("many concurrent advances accept each counter once, in rising order", async () => {
  const { key, storage } = await registeredKey();
  const counters = [4, 2, 9, 2, 7, 9, 1, 4];
  const responses = await Promise.all(counters.map((counter) => advance(key, counter)));
  assert.equal((storage.map.get("key") as { counter: number }).counter, 9);
  const written = storage.writes.filter(([name]) => name === "key").map(([, value]) => (value as { counter: number }).counter);
  assert.deepEqual(written, [...new Set(written)].sort((a, b) => a - b));
  assert.equal(responses.filter((response) => response.status === 204).length, written.length - 1);
});

test("two concurrent registrations of one key store it once and keep its counter", async () => {
  const state = memoryState();
  const key = new AttestedKey(state);
  assert.deepEqual(statuses(await Promise.all([put(key), put(key)])), [200, 201]);
  assert.equal((await advance(key, 3)).status, 204);
  // A registration racing an advance never resets the counter.
  await Promise.all([put(key), advance(key, 4)]);
  assert.equal((state.storage.map.get("key") as { counter: number }).counter, 4);
});

test("an idle key is forgotten once, even with requests racing", async () => {
  const { key, storage } = await registeredKey();
  (storage.map.get("key") as { lastUsed: number }).lastUsed = 0;
  const responses = await Promise.all([advance(key, 1), key.fetch(new Request("https://key/")), advance(key, 2)]);
  assert.deepEqual(statuses(responses), [404, 404, 404]);
  assert.equal(storage.map.has("key"), false);
});

test("two concurrent consumes of one challenge: exactly one succeeds", async () => {
  const challenges = new Challenges(memoryState());
  const issue = (c: string) => challenges.fetch(new Request(`https://challenges/issue?c=${c}`, { method: "POST" }));
  const consume = (c: string) => challenges.fetch(new Request(`https://challenges/consume?c=${c}`, { method: "POST" }));
  assert.equal((await issue("one")).status, 204);
  assert.deepEqual(statuses(await Promise.all([consume("one"), consume("one")])), [204, 404]);
  // Issuing and consuming different challenges at once doesn't lose any.
  await Promise.all(["a", "b", "c"].map(issue));
  assert.deepEqual(statuses(await Promise.all(["a", "b", "c", "a"].map(consume))), [204, 204, 204, 404]);
});

test("concurrent counts never pass the daily limit or lose a count", async () => {
  const take = (counter: DailyCount, limit: number, kind = "attested") =>
    counter.fetch(new Request(`https://count/?limit=${limit}&kind=${kind}`, { method: "POST" }));
  const capped = new DailyCount(memoryState());
  assert.deepEqual(statuses(await Promise.all([take(capped, 1), take(capped, 1)])), [204, 429]);

  const state = memoryState();
  const counter = new DailyCount(state);
  await Promise.all(Array.from({ length: 10 }, (_, i) => take(counter, 100, i % 2 ? "attested" : "unattested")));
  const read = (await (await counter.fetch(new Request("https://count/"))).json()) as { count: number; attested: number; unattested: number };
  assert.deepEqual([read.count, read.attested, read.unattested], [10, 5, 5]);
});

test("events are counted for the day apart from assertions, cut to a fixed length", async () => {
  const storage = memoryStorage();
  storage.map.set("2000-01-01 event challenge", 5);
  const counter = new DailyCount(memoryState(storage));
  const note = (name: string) => counter.fetch(new Request(`https://count/?event=${encodeURIComponent(name)}`, { method: "POST" }));
  await Promise.all([note("challenge"), note("challenge"), note("x".repeat(200))]);
  const read = (await (await counter.fetch(new Request("https://count/"))).json()) as { count: number; events: Record<string, number> };
  assert.equal(read.count, 0);
  assert.deepEqual(read.events, { challenge: 2, ["x".repeat(80)]: 1 });
  // An earlier day's events are forgotten.
  assert.ok(![...storage.map.keys()].some((key) => key.startsWith("2000-01-01")));
});

test("concurrent requests claim a key's metric check once a day", async () => {
  const key = new AttestedKey(memoryState());
  const put = await key.fetch(new Request("https://key/", { method: "PUT", body: JSON.stringify({ publicKey: "p", appId: "a", teamId: "t" }) }));
  assert.equal(put.status, 201);
  const claim = () => key.fetch(new Request("https://key/metric-claim", { method: "POST", body: "{}" }));
  assert.deepEqual(statuses(await Promise.all([claim(), claim(), claim()])), [204, 409, 409]);
  // A key with a metric is never claimed again.
  const recorded = await key.fetch(new Request("https://key/metric", { method: "POST", body: JSON.stringify({ metricCheckedAt: Date.now(), riskMetric: 1 }) }));
  assert.equal(recorded.status, 204);
  assert.equal((await claim()).status, 409);
});
