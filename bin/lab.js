#!/usr/bin/env node
"use strict";
// Interactive lab for working out what v.oai.thstatus actually addresses.
//
//   node bin/lab.js <experiment> [<experiment>...]
//   node bin/lab.js --list
//
// Each experiment announces what it sent and what to look for, then holds so
// it can be observed. `agmap` / `fmap` switch the keymap between the OAI
// agent-group keycodes and the normal F13-F24 map; the original is always
// recoverable with `node bin/restore-keymap.js`.

const fs = require("node:fs");
const path = require("node:path");
const { WLDevice } = require("../lib/wl-device.js");
const oai = require("../lib/oai.js");

const RED = 0xff0000, GREEN = 0x00ff00, BLUE = 0x0000ff;
const YELLOW = 0xffff00, MAGENTA = 0xff00ff, CYAN = 0x00ffff;
const PALETTE = [RED, GREEN, BLUE, YELLOW, MAGENTA, CYAN];
const NAMES = ["red", "green", "blue", "yellow", "magenta", "cyan"];

const BACKUP = path.join(__dirname, "..", "backup", "keymap.json");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function log(msg) { console.log(msg); }
function look(msg) { console.log(`    LOOK: ${msg}`); }

async function setKeymap(dev, useOai) {
  const file = JSON.parse(fs.readFileSync(BACKUP, "utf8"));
  const cfg = JSON.parse(file.data);
  const layer = cfg.profiles[0].layers[0];
  if (useOai) {
    layer.layout.keymap[0] = ["KV_OAI_AG00", "KV_OAI_AG01"];
    layer.layout.keymap[1] = ["KV_OAI_AG02", "KV_OAI_AG03", "KV_OAI_AG04", "KV_OAI_AG05"];
  }
  await dev.call("fs.write", { file: "keymap.json", data: JSON.stringify(cfg) });
  const back = await dev.call("fs.read", { file: "keymap.json" });
  const rows = JSON.parse(typeof back === "string" ? back : back.data)
    .profiles[0].layers[0].layout.keymap;
  log(`    keymap now: ${JSON.stringify(rows[0])} ${JSON.stringify(rows[1])}`);
}

const zone = (color, effect = "solid", brightness = 1) => ({
  effect, brightness, speed: 0.5, magic: 1, color,
});

const EXPERIMENTS = {
  async agmap(dev) {
    log("[agmap] binding top six keys to KV_OAI_AG00..AG05");
    await setKeymap(dev, true);
  },

  async fmap(dev) {
    log("[fmap] restoring KC_F13..KC_F24 keymap");
    await setKeymap(dev, false);
  },

  // Does a thread with no sync flags light anything by itself?
  async nosync(dev) {
    log("[nosync] threads 0-5, six distinct colours, NO sync flags");
    look("do any individual keys light, in six different colours?");
    await oai.sendThreadsLighting(dev, PALETTE.map((color, id) => ({
      id, color, brightness: 1, effect: "solid", speed: 0.5,
    })));
    await sleep(8000);
  },

  // If sync means "the whole zone follows this thread", the LAST thread wins
  // and the pad shows one colour: cyan.
  async syncall(dev) {
    log("[syncall] threads 0-5, six distinct colours, syncKeysLighting on ALL");
    look("six different key colours, or ONE colour? if one, which? (last = cyan)");
    await oai.sendThreadsLighting(dev, PALETTE.map((color, id) => ({
      id, color, brightness: 1, effect: "solid", speed: 0.5, syncKeysLighting: true,
    })));
    await sleep(8000);
  },

  // Same question from the other side: one thread at a time, sequentially.
  async sequential(dev) {
    log("[sequential] one thread at a time with syncKeysLighting, 4s each");
    look("does the WHOLE pad change colour each time? (red -> green -> blue)");
    for (const i of [0, 1, 2]) {
      log(`    thread ${i} = ${NAMES[i]}`);
      await oai.sendThreadsLighting(dev, [{
        id: i, color: PALETTE[i], brightness: 1, effect: "solid",
        speed: 0.5, syncKeysLighting: true,
      }]);
      await sleep(4000);
    }
  },

  // Maybe thread ids are 1-based.
  async oneindexed(dev) {
    log("[oneindexed] threads 1-6 instead of 0-5, distinct colours");
    look("any per-key differentiation now?");
    await oai.sendThreadsLighting(dev, PALETTE.map((color, i) => ({
      id: i + 1, color, brightness: 1, effect: "solid", speed: 0.5,
    })));
    await sleep(8000);
  },

  // AG goes to 19; maybe the pad expects a full set.
  async twenty(dev) {
    log("[twenty] threads 0-19, cycling palette");
    look("any per-key differentiation?");
    await oai.sendThreadsLighting(dev, Array.from({ length: 20 }, (_, id) => ({
      id, color: PALETTE[id % PALETTE.length], brightness: 1,
      effect: "solid", speed: 0.5,
    })));
    await sleep(8000);
  },

  // Isolate one thread hard: one bright, everything else explicitly off.
  async single(dev) {
    log("[single] thread 2 GREEN, threads 0,1,3,4,5 explicitly OFF");
    look("does exactly ONE key light green, or the whole zone, or nothing?");
    await oai.sendThreadsLighting(dev, [
      { id: 2, color: GREEN, brightness: 1, effect: "solid", speed: 0.5 },
      ...[0, 1, 3, 4, 5].map((id) => ({ id, brightness: 0, effect: "off" })),
    ]);
    await sleep(8000);
  },

  // Does thread lighting need the keys zone lit first to paint onto?
  async primed(dev) {
    log("[primed] keys zone dim white first, then per-thread colours");
    look("do individual keys take colour on top of the dim base?");
    await oai.sendLightingConfig(dev, {
      keys: zone(0x202020),
      ambient: zone(0, "off", 0),
    });
    await sleep(1500);
    await oai.sendThreadsLighting(dev, PALETTE.map((color, id) => ({
      id, color, brightness: 1, effect: "solid", speed: 0.5,
    })));
    await sleep(8000);
  },

  // Ambient sync, to confirm the flag does something observable at all.
  async ambient(dev) {
    log("[ambient] thread 0 MAGENTA with syncAmbientLighting only");
    look("does the UNDERGLOW turn magenta?");
    await oai.sendThreadsLighting(dev, [{
      id: 0, color: MAGENTA, brightness: 1, effect: "solid",
      speed: 0.5, syncAmbientLighting: true,
    }]);
    await sleep(6000);
  },

  async off(dev) {
    log("[off] everything off");
    await oai.sendLightingConfig(dev, { keys: zone(0, "off", 0), ambient: zone(0, "off", 0) });
    await oai.sendThreadsLighting(dev, Array.from({ length: 6 }, (_, id) => ({
      id, brightness: 0, effect: "off",
    })));
  },
};

async function main() {
  const args = process.argv.slice(2);
  if (!args.length || args[0] === "--list") {
    console.log("experiments:\n  " + Object.keys(EXPERIMENTS).join("\n  "));
    process.exit(0);
  }
  const unknown = args.filter((a) => !(a in EXPERIMENTS));
  if (unknown.length) {
    console.error(`unknown experiment(s): ${unknown.join(", ")}`);
    process.exit(64);
  }

  const dev = WLDevice.open();
  if (!dev) {
    console.error("No device on the HID bus. Press a key to wake it.");
    process.exit(1);
  }
  oai.onNotify(dev, {
    onKey: (k) => console.log(`    << key event: ${JSON.stringify(k)}`),
    onJoystick: (j) => console.log(`    << joystick: ${JSON.stringify(j)}`),
  });

  console.log(`device: ${dev.info.product}  firmware ${JSON.stringify(await dev.call("sys.version"))}\n`);
  for (const name of args) {
    await EXPERIMENTS[name](dev);
    console.log("");
  }
  dev.close();
  process.exit(0);
}

main().catch((e) => {
  console.error("failed:", e.message);
  process.exit(1);
});
