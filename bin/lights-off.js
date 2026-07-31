#!/usr/bin/env node
"use strict";
// Turn every light on the pad off.
//
// Zone state alone is not enough: per-thread lighting overrides the zones, so
// clearing `keys`/`ambient` while threads are still set leaves the pad lit.
// Both have to be cleared.

const { WLDevice } = require("../lib/wl-device.js");
const { allLightsOff } = require("../lib/oai.js");

async function main() {
  const dev = WLDevice.open();
  if (!dev) {
    console.error("No device on the HID bus. Press a key to wake it, then re-run.");
    process.exit(1);
  }
  await allLightsOff(dev);
  console.log("all lights off (threads cleared and zones cleared)");
  dev.close();
  process.exit(0);
}

main().catch((e) => {
  console.error("failed:", e.message);
  process.exit(1);
});
