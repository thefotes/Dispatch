"use strict";
const test = require("node:test");
const assert = require("node:assert");
const { DEFAULTS, aggregate, lightingFor, threadsFor, mergeConfig } = require("../lib/status.js");
const { sortAgents } = require("../lib/herdr-client.js");
const { hexToInt } = require("../lib/wl-device.js");

const agent = (agent_status, pane_id = "w1:p1") => ({ agent_status, pane_id });

test("no agents means the light goes off", () => {
  assert.strictEqual(aggregate([]), null);
  assert.strictEqual(aggregate(undefined), null);
  assert.strictEqual(lightingFor(null), null);
});

test("a blocked agent outranks working and idle", () => {
  const state = aggregate([
    agent("idle", "w1:p1"),
    agent("working", "w1:p2"),
    agent("blocked", "w1:p3"),
  ]);
  assert.strictEqual(state, "blocked");
  assert.strictEqual(lightingFor(state).color, "#FF2D2D");
});

test("working outranks idle and done", () => {
  const state = aggregate([agent("done"), agent("idle"), agent("working")]);
  assert.strictEqual(state, "working");
  assert.strictEqual(lightingFor(state).color, "#FFA000");
});

test("all idle or done is the calm colour", () => {
  assert.strictEqual(aggregate([agent("idle"), agent("done")]), "idle");
  assert.strictEqual(lightingFor("idle").color, "#00C853");
  assert.strictEqual(lightingFor("done").color, "#00C853");
});

test("an unrecognised status still yields a state rather than throwing", () => {
  assert.strictEqual(aggregate([agent("wat")]), "unknown");
  assert.ok(lightingFor(aggregate([agent("wat")])).color);
});

test("blocked breathes so it reads differently from a steady colour", () => {
  assert.strictEqual(lightingFor("blocked").effect, "breath");
  assert.strictEqual(lightingFor("working").effect, "solid");
});

test("user config overrides merge over defaults instead of replacing them", () => {
  const cfg = mergeConfig({ colors: { blocked: "#123456" }, brightness: 0.4 });
  assert.strictEqual(cfg.colors.blocked, "#123456");
  assert.strictEqual(cfg.colors.working, DEFAULTS.colors.working, "untouched keys survive");
  assert.strictEqual(cfg.brightness, 0.4);
  assert.deepStrictEqual(cfg.priority, DEFAULTS.priority);
});

test("slot order is stable regardless of the order the API returns agents", () => {
  const a = { workspace_id: "w1", tab_id: "w1:t1", pane_id: "w1:p1" };
  const b = { workspace_id: "w1", tab_id: "w1:t2", pane_id: "w1:p2" };
  const c = { workspace_id: "w2", tab_id: "w2:t1", pane_id: "w2:p1" };
  const expected = sortAgents([a, b, c]).map((x) => x.pane_id);
  assert.deepStrictEqual(sortAgents([c, a, b]).map((x) => x.pane_id), expected);
  assert.deepStrictEqual(sortAgents([b, c, a]).map((x) => x.pane_id), expected);
});

test("colours convert to the integer the firmware expects", () => {
  assert.strictEqual(hexToInt("#FF2D2D"), 0xff2d2d);
  assert.strictEqual(hexToInt("00C853"), 0x00c853);
  assert.strictEqual(hexToInt("#0f0"), 0x00ff00);
});

// ---- per-key mapping (vendor thread API) ----

test("each agent gets its own key, in slot order", () => {
  const threads = threadsFor([
    agent("working"), agent("blocked"), agent("idle"),
  ]);
  assert.strictEqual(threads.length, 6, "one entry per agent key");
  assert.deepStrictEqual(threads.map((t) => t.id), [0, 1, 2, 3, 4, 5], "ids are 0-based key indices");
  assert.strictEqual(threads[0].color, "#FFA000");
  assert.strictEqual(threads[1].color, "#FF2D2D");
  assert.strictEqual(threads[2].color, "#00C853");
});

test("keys with no agent are switched off, not left stale", () => {
  const threads = threadsFor([agent("working")]);
  for (const t of threads.slice(1)) {
    assert.strictEqual(t.effect, "off");
    assert.strictEqual(t.brightness, 0);
    assert.strictEqual(t.color, undefined, "no colour on an unused key");
  }
});

test("a blocked agent breathes on its own key", () => {
  const threads = threadsFor([agent("idle"), agent("blocked")]);
  assert.strictEqual(threads[0].effect, "solid");
  assert.strictEqual(threads[1].effect, "breath");
});

test("more agents than keys does not overflow the key set", () => {
  const many = Array.from({ length: 9 }, () => agent("working"));
  assert.strictEqual(threadsFor(many).length, 6);
});

test("no agents leaves every key dark", () => {
  assert.ok(threadsFor([]).every((t) => t.effect === "off"));
});

test("per-key colours honour config overrides", () => {
  const cfg = mergeConfig({ colors: { working: "#123456" }, brightness: 0.3 });
  const t = threadsFor([agent("working")], cfg)[0];
  assert.strictEqual(t.color, "#123456");
  assert.strictEqual(t.brightness, 0.3);
});
