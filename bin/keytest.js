#!/usr/bin/env node
"use strict";
// Visual test: is `keys` in v.oai.rgbcfg a per-key array, or just the name of
// the key-backlight surface?
//
// The firmware answers {"ok":1} to anything, including {}, so the wire response
// proves nothing. Only the device can answer this. Each step holds long enough
// to look at the pad.

const { WLDevice } = require("../lib/wl-device.js");

const RED = 0xff0000, GREEN = 0x00ff00, BLUE = 0x0000ff;
const MAGENTA = 0xff00ff, CYAN = 0x00ffff, YELLOW = 0xffff00, WHITE = 0xffffff;

const surface = (color) => ({
  effect: "solid",
  brightness: 1,
  speed: 0.5,
  magic: 1,
  color,
});

// 13 keys: rows of 2, 4, 4, 3.
const RAINBOW = [RED, GREEN, BLUE, YELLOW, MAGENTA, CYAN, WHITE, RED, GREEN, BLUE, YELLOW, MAGENTA, CYAN];

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function step(dev, n, what, look, method, params, hold = 5000) {
  console.log(`\n[${n}] ${what}`);
  console.log(`    LOOK FOR: ${look}`);
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
    console.error("No Work Louder device on the HID bus. Press a key to wake it.");
    process.exit(1);
  }
  console.log(`device: ${dev.info.product}`);
  console.log("Watch the pad. Each step holds for 5 seconds.");

  await step(dev, 1, "keys=RED, ambient=BLUE", "keys red, underglow blue?", "v.oai.rgbcfg", {
    keys: surface(RED),
    ambient: surface(BLUE),
  });

  await step(dev, 2, "keys=BLUE, ambient=RED", "did they swap?", "v.oai.rgbcfg", {
    keys: surface(BLUE),
    ambient: surface(RED),
  });

  console.log("\n--- per-key attempts: do individual keys differ, or all one colour? ---");

  await step(dev, 3, "keys = bare array of 13 colours", "MULTIPLE different key colours?", "v.oai.rgbcfg", {
    keys: RAINBOW,
  });

  await step(dev, 4, "keys.colors = array of 13", "MULTIPLE different key colours?", "v.oai.rgbcfg", {
    keys: { colors: RAINBOW },
  });

  await step(dev, 5, "keys.leds = [{index,color}]", "MULTIPLE different key colours?", "v.oai.rgbcfg", {
    keys: { leds: RAINBOW.map((color, index) => ({ index, color })) },
  });

  await step(dev, 6, "keys = [{index,color}]", "MULTIPLE different key colours?", "v.oai.rgbcfg", {
    keys: RAINBOW.map((color, index) => ({ index, color })),
  });

  await step(dev, 7, "keys.keys = [{i,c}]", "MULTIPLE different key colours?", "v.oai.rgbcfg", {
    keys: { keys: RAINBOW.map((c, i) => ({ i, c })) },
  });

  console.log("\nrestoring (all off)");
  await dev.call("v.oai.rgbcfg", {
    keys: { effect: "off", brightness: 0, speed: 0.5, magic: 1, color: 0 },
    ambient: { effect: "off", brightness: 0, speed: 0.5, magic: 1, color: 0 },
  });
  dev.close();
  console.log("done");
  process.exit(0);
}

main().catch((e) => {
  console.error("failed:", e.message);
  process.exit(1);
});
