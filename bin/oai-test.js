#!/usr/bin/env node
"use strict";
// Verify the recovered OAI lighting protocol against the real device.
//
// Step 1 proves the zone API works with the correct wire shape (abbreviated
// keys + numeric effect). Step 2 is the one that matters: distinct colours on
// distinct threads. Step 3 listens for device-pushed key events.

const { WLDevice } = require("../lib/wl-device.js");
const oai = require("../lib/oai.js");

const RED = 0xff0000, GREEN = 0x00ff00, BLUE = 0x0000ff;
const YELLOW = 0xffff00, MAGENTA = 0xff00ff, CYAN = 0x00ffff;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function main() {
  const dev = WLDevice.open();
  if (!dev) {
    console.error("No device on the HID bus. Press a key to wake it.");
    process.exit(1);
  }
  console.log(`device: ${dev.info.product}`);
  console.log(`firmware: ${JSON.stringify(await dev.call("sys.version"))}\n`);

  // Log every device-pushed notification for the whole run.
  oai.onNotify(dev, {
    onKey: (k) => console.log(`    << key event: ${JSON.stringify(k)}`),
    onJoystick: (j) => console.log(`    << joystick: ${JSON.stringify(j)}`),
  });

  console.log("== 1. zone lighting via v.oai.rgbcfg, correct wire shape ==");
  console.log("   LOOK: keys RED, ambient BLUE");
  await oai.sendLightingConfig(dev, {
    keys: { effect: "solid", brightness: 1, speed: 0.5, magic: 1, color: RED },
    ambient: { effect: "solid", brightness: 1, speed: 0.5, magic: 1, color: BLUE },
  });
  await sleep(5000);

  console.log("   LOOK: swapped - keys BLUE, ambient RED");
  await oai.sendLightingConfig(dev, {
    keys: { effect: "solid", brightness: 1, speed: 0.5, magic: 1, color: BLUE },
    ambient: { effect: "solid", brightness: 1, speed: 0.5, magic: 1, color: RED },
  });
  await sleep(5000);

  console.log("\n== 2. PER-THREAD lighting via v.oai.thstatus ==");
  const palette = [RED, GREEN, BLUE, YELLOW, MAGENTA, CYAN];
  console.log("   LOOK: six DIFFERENT colours across the agent keys");
  console.log("   (red, green, blue, yellow, magenta, cyan)");
  await oai.sendThreadsLighting(
    dev,
    palette.map((color, id) => ({
      id,
      color,
      brightness: 1,
      effect: "solid",
      speed: 0.5,
      syncKeysLighting: true,
    })),
  );
  await sleep(8000);

  console.log("   LOOK: same six, rotated by one");
  await oai.sendThreadsLighting(
    dev,
    palette.map((_, id) => ({
      id,
      color: palette[(id + 1) % palette.length],
      brightness: 1,
      effect: "solid",
      syncKeysLighting: true,
    })),
  );
  await sleep(8000);

  console.log("   LOOK: only thread 0 red-breathing, the rest off");
  await oai.sendThreadsLighting(dev, [
    { id: 0, color: RED, brightness: 1, effect: "breath", speed: 0.5, syncKeysLighting: true },
    ...[1, 2, 3, 4, 5].map((id) => ({ id, effect: "off", brightness: 0, syncKeysLighting: true })),
  ]);
  await sleep(8000);

  console.log("\n== 3. key events ==");
  console.log("   PRESS a few keys on the pad now (10 seconds)...");
  await sleep(10000);

  console.log("\nrestoring: all off");
  await oai.sendLightingConfig(dev, {
    keys: { effect: "off", brightness: 0, speed: 0.5, magic: 1, color: 0 },
    ambient: { effect: "off", brightness: 0, speed: 0.5, magic: 1, color: 0 },
  });
  dev.close();
  process.exit(0);
}

main().catch((e) => {
  console.error("failed:", e.message);
  process.exit(1);
});
