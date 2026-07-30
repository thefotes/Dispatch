#!/usr/bin/env node
"use strict";
// Visual test. Everything else is exhausted: the firmware returns {"ok":1} to
// any payload (including malformed ones), emits no debug log over HID, and its
// persisted keymap.json stores lighting as exactly two surfaces
// (backlight/underglow) with one colour each. So only the LEDs can tell us
// whether `keys` is per-key addressable or just the key-backlight surface.
//
// Watch the pad. Each step announces what to look for and holds 5 seconds.

const { WLDevice } = require("../lib/wl-device.js");

const RED = 0xff0000, GREEN = 0x00ff00, BLUE = 0x0000ff, YELLOW = 0xffff00;
const MAGENTA = 0xff00ff, CYAN = 0x00ffff, WHITE = 0xffffff;
const ALT = [RED, GREEN, BLUE, YELLOW, MAGENTA, CYAN, WHITE, RED, GREEN, BLUE, YELLOW, MAGENTA, CYAN];

const surface = (color, effect = "solid") => ({
  effect, brightness: 1, speed: 0.5, magic: 1, color,
});

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function step(dev, n, what, look, method, params, hold = 5000) {
  console.log(`\n[${n}] ${what}`);
  console.log(`    LOOK: ${look}`);
  try {
    await dev.call(method, params);
  } catch (err) {
    console.log(`    (device said: ${err.message})`);
    return;
  }
  await sleep(hold);
}

async function main() {
  const dev = WLDevice.open();
  if (!dev) {
    console.error("No device on the HID bus. Press a key to wake it, then re-run.");
    process.exit(1);
  }
  const v = await dev.call("sys.version").catch(() => ({}));
  console.log(`device: ${dev.info.product}   firmware: ${JSON.stringify(v)}`);
  console.log("Watch the pad. 11 steps, 5 seconds each (~1 minute).");

  // --- Part A: are `keys` and `ambient` two distinct surfaces? ---
  console.log("\n########## PART A: are keys and ambient different lights? ##########");

  await step(dev, "A1", "keys=RED  ambient=BLUE", "which light is red, which is blue?",
    "v.oai.rgbcfg", { keys: surface(RED), ambient: surface(BLUE) });

  await step(dev, "A2", "keys=BLUE  ambient=RED", "did the two lights SWAP?",
    "v.oai.rgbcfg", { keys: surface(BLUE), ambient: surface(RED) });

  await step(dev, "A3", "keys=GREEN  ambient=off", "is ONLY the key backlight lit (green)?",
    "v.oai.rgbcfg", { keys: surface(GREEN), ambient: surface(0, "off") });

  await step(dev, "A4", "keys=off  ambient=GREEN", "is ONLY the underglow lit (green)?",
    "v.oai.rgbcfg", { keys: surface(0, "off"), ambient: surface(GREEN) });

  // --- Part B: per-key addressing ---
  console.log("\n########## PART B: can individual keys differ? ##########");
  console.log("For every step below the question is the same:");
  console.log("  do keys show DIFFERENT colours from each other, or all ONE colour?");

  await step(dev, "B1", "keys = bare array of 13 colours", "different colours per key?",
    "v.oai.rgbcfg", { keys: ALT });

  await step(dev, "B2", "keys.color = array of 13", "different colours per key?",
    "v.oai.rgbcfg", { keys: { effect: "solid", brightness: 1, speed: 0.5, magic: 1, color: ALT } });

  await step(dev, "B3", "keys.colors = array of 13", "different colours per key?",
    "v.oai.rgbcfg", { keys: { colors: ALT } });

  await step(dev, "B4", "keys.leds = [{index,color}]", "different colours per key?",
    "v.oai.rgbcfg", { keys: { leds: ALT.map((color, index) => ({ index, color })) } });

  // --- Part C: thstatus ---
  console.log("\n########## PART C: does thstatus do anything visible? ##########");

  await step(dev, "C1", "thstatus = 1", "ANY change: animation, key colours, underglow?",
    "v.oai.thstatus", { status: 1 });

  await step(dev, "C2", "thstatus per-slot array", "ANY change, especially the top 6 keys?",
    "v.oai.thstatus", { status: [1, 2, 3, 0, 1, 2] });

  await step(dev, "C3", "thstatus act=1", "ANY change?",
    "v.oai.thstatus", { act: 1 });

  console.log("\nrestoring (all off)");
  await dev.call("v.oai.rgbcfg", {
    keys: surface(0, "off"),
    ambient: surface(0, "off"),
  }).catch(() => {});
  await dev.call("v.oai.thstatus", { status: 0 }).catch(() => {});
  dev.close();
  console.log("done");
  process.exit(0);
}

main().catch((e) => {
  console.error("failed:", e.message);
  process.exit(1);
});
