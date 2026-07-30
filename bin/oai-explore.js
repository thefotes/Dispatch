#!/usr/bin/env node
"use strict";
// Explore the v.oai.* handlers by listening to the firmware's debug log.
//
// Every payload gets {"ok":1} back, so the RPC reply tells us nothing about
// whether the firmware understood the shape. But the same HID pipe carries a
// firmware log on channel 1 (that is where "OAI BRIDGE: init ..." comes from),
// so anything the handler logs while parsing shows up there.

const { WLDevice } = require("../lib/wl-device.js");

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const RED = 0xff0000, GREEN = 0x00ff00, BLUE = 0x0000ff, YELLOW = 0xffff00;
const PER_KEY = [RED, GREEN, BLUE, YELLOW, RED, GREEN, BLUE, YELLOW, RED, GREEN, BLUE, YELLOW, RED];

async function main() {
  const dev = WLDevice.open();
  if (!dev) {
    console.error("no device; press a key to wake it");
    process.exit(1);
  }

  let captured = [];
  dev.onDebug = (text) => captured.push(text);

  console.log(`device: ${dev.info.product}`);
  const v = await dev.call("sys.version").catch(() => ({}));
  console.log(`firmware: ${JSON.stringify(v)}\n`);

  const cases = [
    // v.oai.thstatus: the bridge sits next to AG%02u/ACT%02u and
    // syncKeysLighting, so it plausibly takes per-slot status values.
    ["thstatus", "v.oai.thstatus", [0, 1, 2, 3, 4, 5]],
    ["thstatus", "v.oai.thstatus", { status: [0, 1, 2, 3, 4, 5] }],
    ["thstatus", "v.oai.thstatus", { keys: [0, 1, 2, 3, 4, 5] }],
    ["thstatus", "v.oai.thstatus", { agents: [0, 1, 2, 3, 4, 5] }],
    ["thstatus", "v.oai.thstatus", { act: 1 }],
    ["thstatus", "v.oai.thstatus", { act: [0, 1, 2, 3, 4, 5] }],
    ["thstatus", "v.oai.thstatus", { index: 0, status: 1 }],
    ["thstatus", "v.oai.thstatus", { idx: 0, act: 1 }],
    ["thstatus", "v.oai.thstatus", { slot: 0, color: RED }],
    ["thstatus", "v.oai.thstatus", { thinking: [true, false, true, false, true, false] }],
    // v.oai.rgbcfg per-key candidates.
    ["rgbcfg", "v.oai.rgbcfg", { keys: PER_KEY }],
    ["rgbcfg", "v.oai.rgbcfg", { keys: { color: PER_KEY } }],
    ["rgbcfg", "v.oai.rgbcfg", { keys: { effect: "solid", color: PER_KEY, brightness: 1 } }],
    // Deliberately malformed, to learn what a rejection looks like.
    ["control", "v.oai.rgbcfg", { keys: "not-a-thing" }],
    ["control", "v.oai.rgbcfg", { nonsense: { deeply: { nested: true } } }],
  ];

  for (const entry of cases) {
    const [group, method, params] = entry;
    captured = [];
    let reply;
    try {
      reply = JSON.stringify(await dev.call(method, params));
    } catch (err) {
      reply = `ERROR ${err.message}`;
    }
    await sleep(350); // give the log a moment to arrive
    const log = captured.join("").trim();
    console.log(`[${group}] ${method} ${JSON.stringify(params).slice(0, 70)}`);
    console.log(`    reply: ${reply}`);
    if (log) console.log(`    LOG:   ${log.replace(/\n/g, "\n           ")}`);
  }

  console.log("\nrestoring");
  await dev.call("v.oai.rgbcfg", {
    keys: { effect: "off", brightness: 0, speed: 0.5, magic: 1, color: 0 },
    ambient: { effect: "off", brightness: 0, speed: 0.5, magic: 1, color: 0 },
  }).catch(() => {});
  dev.close();
  process.exit(0);
}

main().catch((e) => {
  console.error("failed:", e.message);
  process.exit(1);
});
