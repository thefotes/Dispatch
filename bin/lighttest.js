#!/usr/bin/env node
"use strict";
// Establish a baseline: does ANY host lighting call visibly affect this pad?
//
// The earlier test used v.oai.rgbcfg with keys/ambient and produced no visible
// change whatsoever - not even between two obviously different colours. Before
// concluding anything about per-key addressing we need to know whether the
// known-good path works at all: `lights.preview` with the backlight/underglow
// section names that the device's own keymap.json uses.
//
// Each state is re-asserted every 250ms so that Work Louder's Input app (which
// pushes its own lighting on app-focus changes) cannot quietly overwrite it,
// and so a preview that expires gets refreshed.

const { WLDevice } = require("../lib/wl-device.js");

const RED = 0xff0000, BLUE = 0x0000ff, GREEN = 0x00ff00;

const surface = (color, effect = "solid") => ({
  effect, brightness: 1, speed: 0.5, magic: 1, color,
});

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function hold(dev, label, look, method, params, ms = 6000) {
  console.log(`\n>>> ${label}`);
  console.log(`    LOOK: ${look}`);
  const until = Date.now() + ms;
  let sent = 0, failed = null;
  while (Date.now() < until) {
    try {
      await dev.call(method, params);
      sent++;
    } catch (err) {
      failed = err.message;
      break;
    }
    await sleep(250);
  }
  console.log(`    (re-sent ${sent}x${failed ? `, then failed: ${failed}` : ""})`);
}

async function main() {
  const dev = WLDevice.open();
  if (!dev) {
    console.error("No device on the HID bus. Press a key to wake it.");
    process.exit(1);
  }
  const st = await dev.call("device.status").catch(() => ({}));
  console.log(`device: ${dev.info.product}`);
  console.log(`status: ${JSON.stringify(st)}`);
  console.log("\nWatch the pad. 5 states, 6 seconds each (~30s).");

  await hold(dev, "1. lights.preview  backlight=RED  underglow=BLUE",
    "key backlight red, underglow blue?",
    "lights.preview", { backlight: surface(RED), underglow: surface(BLUE) });

  await hold(dev, "2. lights.preview  backlight=BLUE  underglow=RED",
    "did they SWAP?",
    "lights.preview", { backlight: surface(BLUE), underglow: surface(RED) });

  await hold(dev, "3. lights.preview  everything GREEN, full brightness",
    "is the whole pad green?",
    "lights.preview", { backlight: surface(GREEN), underglow: surface(GREEN) });

  await hold(dev, "4. lights.preview  everything OFF",
    "did all lighting go DARK?",
    "lights.preview", { backlight: surface(0, "off"), underglow: surface(0, "off") });

  await hold(dev, "5. lights.preview  underglow RAINBOW",
    "is the underglow cycling colours?",
    "lights.preview", { backlight: surface(0, "off"), underglow: surface(0xffffff, "rainbow") });

  console.log("\nleaving lighting as-is (change layers on the pad to restore your normal config)");
  dev.close();
  process.exit(0);
}

main().catch((e) => {
  console.error("failed:", e.message);
  process.exit(1);
});
