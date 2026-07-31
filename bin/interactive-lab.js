#!/usr/bin/env node
"use strict";
// Interactive protocol lab for the Work Louder OAI vendor lighting API.
//
// We know the wire shape is right (abbreviated keys, numeric effects) because
// the lights respond. What we do not know is what a "thread" addresses: an
// individual key, or a shared zone.
//
// Each test applies a lighting state, leaves it on screen, and asks what you
// see. The state stays applied while you answer, so there is no timing to get
// right. Answers are recorded and summarised at the end.
//
//   node bin/interactive-lab.js            run everything
//   node bin/interactive-lab.js 3 4 7      run only those tests
//
// Your keymap is restored and the lights turned off on every exit path.

const fs = require("node:fs");
const path = require("node:path");
const readline = require("node:readline");
const { WLDevice } = require("../lib/wl-device.js");
const oai = require("../lib/oai.js");

const RED = 0xff0000, GREEN = 0x00ff00, BLUE = 0x0000ff;
const YELLOW = 0xffff00, MAGENTA = 0xff00ff, CYAN = 0x00ffff, WHITE = 0xffffff;
const PALETTE = [RED, GREEN, BLUE, YELLOW, MAGENTA, CYAN];
const PNAMES = ["red", "green", "blue", "yellow", "magenta", "cyan"];

const BACKUP = path.join(__dirname, "..", "backup", "keymap.json");
const RESULTS = path.join(__dirname, "..", "backup", "lab-results.json");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const zone = (color, effect = "solid", brightness = 1) => ({
  effect, brightness, speed: 0.5, magic: 1, color,
});

// ---------- answer sets ----------
const A_KEYS = [
  "nothing changed",
  "ALL keys one colour",
  "individual keys showing DIFFERENT colours",
  "only the underglow changed",
  "keys AND underglow changed together",
  "something else (I'll describe it)",
];
const A_YESNO = ["yes", "no", "partly / something else"];

// ---------- tests ----------
// Each: { name, why, look, run(dev), options }
const TESTS = [
  {
    name: "baseline zones",
    why: "Confirm the zone API still works, so a null result later means something.",
    look: "keys RED, underglow BLUE",
    options: A_KEYS,
    run: (dev) => oai.sendLightingConfig(dev, { keys: zone(RED), ambient: zone(BLUE) }),
  },
  {
    name: "threads, no sync flags",
    why: "Do threads paint anything on their own, without a sync flag?",
    look: "six different key colours (red green blue yellow magenta cyan)",
    options: A_KEYS,
    run: (dev) => oai.sendThreadsLighting(dev, PALETTE.map((color, id) => ({
      id, color, brightness: 1, effect: "solid", speed: 0.5,
    }))),
  },
  {
    name: "threads, syncKeysLighting on all six",
    why: "If a thread mirrors onto the whole key zone, the LAST one wins and you get cyan.",
    look: "six different colours, or ONE colour? if one, is it CYAN (last) or RED (first)?",
    options: [
      "nothing changed",
      "ALL keys one colour - CYAN (last thread wins)",
      "ALL keys one colour - RED (first thread wins)",
      "ALL keys one colour - some other colour",
      "individual keys showing DIFFERENT colours",
      "something else (I'll describe it)",
    ],
    run: (dev) => oai.sendThreadsLighting(dev, PALETTE.map((color, id) => ({
      id, color, brightness: 1, effect: "solid", speed: 0.5, syncKeysLighting: true,
    }))),
  },
  {
    name: "single thread 2 green, others explicitly off",
    why: "Isolates one thread. If ids map to keys, exactly one key lights.",
    look: "exactly ONE key green, or the whole zone green, or nothing",
    options: [
      "nothing changed",
      "exactly ONE key lit green",
      "ALL keys green",
      "only the underglow went green",
      "something else (I'll describe it)",
    ],
    run: (dev) => oai.sendThreadsLighting(dev, [
      { id: 2, color: GREEN, brightness: 1, effect: "solid", speed: 0.5 },
      ...[0, 1, 3, 4, 5].map((id) => ({ id, brightness: 0, effect: "off" })),
    ]),
  },
  {
    name: "single thread 2 green + syncKeysLighting",
    why: "Same isolation, but with the flag that is documented to drive the key zone.",
    look: "exactly ONE key green, or the whole zone green",
    options: [
      "nothing changed",
      "exactly ONE key lit green",
      "ALL keys green",
      "only the underglow went green",
      "something else (I'll describe it)",
    ],
    run: (dev) => oai.sendThreadsLighting(dev, [
      { id: 2, color: GREEN, brightness: 1, effect: "solid", speed: 0.5, syncKeysLighting: true },
      ...[0, 1, 3, 4, 5].map((id) => ({ id, brightness: 0, effect: "off" })),
    ]),
  },
  {
    name: "thread ids 1-6 instead of 0-5",
    why: "The id space might be 1-based; 0 could be 'no thread'.",
    look: "any per-key differentiation now?",
    options: A_KEYS,
    run: (dev) => oai.sendThreadsLighting(dev, PALETTE.map((color, i) => ({
      id: i + 1, color, brightness: 1, effect: "solid", speed: 0.5, syncKeysLighting: true,
    }))),
  },
  {
    name: "twenty threads (0-19)",
    why: "The firmware keycode table goes to KV_OAI_AG19; maybe it wants a full set.",
    look: "any per-key differentiation?",
    options: A_KEYS,
    run: (dev) => oai.sendThreadsLighting(dev, Array.from({ length: 20 }, (_, id) => ({
      id, color: PALETTE[id % 6], brightness: 1, effect: "solid", speed: 0.5,
    }))),
  },
  {
    name: "keys zone primed dim, then threads",
    why: "Thread colour may only paint on top of an already-active key zone.",
    look: "individual keys taking colour over a dim white base",
    options: A_KEYS,
    run: async (dev) => {
      await oai.sendLightingConfig(dev, { keys: zone(0x181818), ambient: zone(0, "off", 0) });
      await sleep(1200);
      return oai.sendThreadsLighting(dev, PALETTE.map((color, id) => ({
        id, color, brightness: 1, effect: "solid", speed: 0.5,
      })));
    },
  },
  {
    name: "syncAmbientLighting only",
    why: "Confirms the sync flags do something observable at all.",
    look: "does the UNDERGLOW turn magenta?",
    options: A_YESNO,
    run: (dev) => oai.sendThreadsLighting(dev, [{
      id: 0, color: MAGENTA, brightness: 1, effect: "solid", speed: 0.5,
      syncAmbientLighting: true,
    }]),
  },
  {
    name: "per-thread EFFECT differences",
    why: "If per-key colour is out, per-key animation might still be in.",
    look: "any key breathing/animating differently from the others?",
    options: A_YESNO,
    run: (dev) => oai.sendThreadsLighting(dev, [
      { id: 0, color: WHITE, brightness: 1, effect: "breath", speed: 0.8, syncKeysLighting: true },
      { id: 1, color: WHITE, brightness: 1, effect: "solid", speed: 0.5 },
      { id: 2, color: WHITE, brightness: 1, effect: "rainbow", speed: 0.5 },
    ]),
  },
  {
    name: "walk: one thread at a time, 0 through 12",
    why: "If ids map to keys, you should see a single lit key travel across the pad.",
    look: "watch for a single lit key MOVING across the pad, ~1.5s per step",
    options: [
      "nothing moved",
      "a single key moved across the pad",
      "the whole zone flashed each step",
      "something else (I'll describe it)",
    ],
    run: async (dev) => {
      for (let id = 0; id <= 12; id++) {
        await oai.sendThreadsLighting(dev, [
          { id, color: WHITE, brightness: 1, effect: "solid", speed: 0.5 },
          ...Array.from({ length: 13 }, (_, i) => i)
            .filter((i) => i !== id)
            .map((i) => ({ id: i, brightness: 0, effect: "off" })),
        ]);
        await sleep(1500);
      }
    },
  },
  {
    name: "zone keys=off but threads bright",
    why: "Checks whether the keys zone acts as a master switch over thread colour.",
    look: "anything at all on the keys?",
    options: A_YESNO,
    run: async (dev) => {
      await oai.sendLightingConfig(dev, { keys: zone(0, "off", 0), ambient: zone(0, "off", 0) });
      await sleep(800);
      return oai.sendThreadsLighting(dev, PALETTE.map((color, id) => ({
        id, color, brightness: 1, effect: "solid", speed: 0.5,
      })));
    },
  },
];

// ---------- prompting ----------
function makeAsk(rl) {
  return (question) => new Promise((resolve) => rl.question(question, resolve));
}

async function askChoice(ask, options) {
  options.forEach((o, i) => console.log(`      ${i + 1}. ${o}`));
  for (;;) {
    const raw = (await ask("\n    your answer (number, or 's' to skip): ")).trim().toLowerCase();
    if (raw === "s") return { choice: "skipped" };
    const n = parseInt(raw, 10);
    if (Number.isInteger(n) && n >= 1 && n <= options.length) {
      const choice = options[n - 1];
      if (/something else|describe/.test(choice)) {
        const note = (await ask("    describe what you saw: ")).trim();
        return { choice, note };
      }
      return { choice };
    }
    console.log("    please enter a number from the list, or 's' to skip.");
  }
}

async function setKeymap(dev, useOai) {
  const file = JSON.parse(fs.readFileSync(BACKUP, "utf8"));
  const cfg = JSON.parse(file.data);
  const layer = cfg.profiles[0].layers[0];
  if (useOai) {
    layer.layout.keymap[0] = ["KV_OAI_AG00", "KV_OAI_AG01"];
    layer.layout.keymap[1] = ["KV_OAI_AG02", "KV_OAI_AG03", "KV_OAI_AG04", "KV_OAI_AG05"];
  }
  await dev.call("fs.write", { file: "keymap.json", data: JSON.stringify(cfg) });
}

async function main() {
  const wanted = process.argv.slice(2).map((n) => parseInt(n, 10)).filter(Number.isInteger);
  const dev = WLDevice.open();
  if (!dev) {
    console.error("No device on the HID bus. Press a key to wake it, then re-run.");
    process.exit(1);
  }

  const keyEvents = [];
  oai.onNotify(dev, {
    onKey: (k) => keyEvents.push(k),
    onJoystick: () => {},
  });

  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  const ask = makeAsk(rl);
  const results = [];
  let cleaned = false;

  const cleanup = async () => {
    if (cleaned) return;
    cleaned = true;
    try {
      // Thread state overrides the zones, so both have to be cleared.
      await oai.allLightsOff(dev);
      await setKeymap(dev, false);
      console.log("\nkeymap restored (F13-F24), lights off.");
    } catch (err) {
      console.error(`\nCLEANUP FAILED: ${err.message}`);
      console.error("Run: node bin/restore-keymap.js");
    }
    try { rl.close(); } catch {}
    try { dev.close(); } catch {}
  };
  process.on("SIGINT", async () => { await cleanup(); process.exit(130); });

  try {
    const version = await dev.call("sys.version");
    console.log(`\ndevice:   ${dev.info.product}`);
    console.log(`firmware: ${JSON.stringify(version)}`);
    console.log("\nBinding the top six keys to KV_OAI_AG00..AG05 for the duration.");
    await setKeymap(dev, true);
    console.log("Answer with a number after each test. 's' skips. Ctrl-C is safe.\n");

    for (let i = 0; i < TESTS.length; i++) {
      const num = i + 1;
      if (wanted.length && !wanted.includes(num)) continue;
      const t = TESTS[i];
      console.log("=".repeat(64));
      console.log(`TEST ${num}/${TESTS.length}  ${t.name}`);
      console.log(`  why:  ${t.why}`);
      console.log(`  LOOK: ${t.look}`);
      console.log("");
      try {
        await t.run(dev);
      } catch (err) {
        console.log(`  (device error: ${err.message})`);
      }
      const answer = await askChoice(ask, t.options);
      results.push({ test: num, name: t.name, ...answer });
      console.log("");
    }

    if (keyEvents.length) {
      console.log(`\nDevice pushed ${keyEvents.length} key event(s) during the run:`);
      console.log(JSON.stringify(keyEvents.slice(0, 10), null, 1));
    } else {
      console.log("\nNo v.oai.hid key events were pushed during the run.");
    }

    fs.writeFileSync(RESULTS, JSON.stringify({ version, results, keyEvents }, null, 2));
    console.log("\n" + "=".repeat(64));
    console.log("SUMMARY");
    for (const r of results) {
      console.log(`  ${String(r.test).padStart(2)}. ${r.name}`);
      console.log(`      -> ${r.choice}${r.note ? ` -- "${r.note}"` : ""}`);
    }
    console.log(`\nsaved to ${path.relative(process.cwd(), RESULTS)}`);
  } finally {
    await cleanup();
  }
  process.exit(0);
}

main().catch(async (e) => {
  console.error("failed:", e.message);
  process.exit(1);
});
