#!/usr/bin/env node
"use strict";
// Bind the six agent keys to KV_OAI_AG00..AG05, which is what makes them
// individually lightable. Every other key, layer and setting is left alone.
//
// Those six keys stop sending keystrokes once bound — that is the trade-off,
// not a bug. Use `node bin/restore-keymap.js` to put the original map back.

const { WLDevice } = require("../lib/wl-device.js");
const { readKeymap, applyAgentKeymap, activeLayer } = require("../lib/keymap.js");

async function main() {
  const dev = WLDevice.open();
  if (!dev) {
    console.error("No device on the HID bus. Press a key to wake it, then re-run.");
    process.exit(1);
  }

  const before = await readKeymap(dev);
  console.log("before:", JSON.stringify(activeLayer(before.config).layout.keymap));

  const { changed, config } = await applyAgentKeymap(dev);
  console.log("after: ", JSON.stringify(activeLayer(config).layout.keymap));
  console.log(changed ? "agent keymap applied" : "already applied, nothing to do");

  dev.close();
  process.exit(0);
}

main().catch((e) => {
  console.error("failed:", e.message);
  process.exit(1);
});
