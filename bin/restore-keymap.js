#!/usr/bin/env node
"use strict";
// Restore the device keymap from backup/keymap.json. Safety net for the
// experiments in bin/oai-keymap-test.js.

const fs = require("node:fs");
const path = require("node:path");
const { WLDevice } = require("../lib/wl-device.js");

async function main() {
  const backup = path.join(__dirname, "..", "backup", "keymap.json");
  const raw = fs.readFileSync(backup, "utf8");
  const parsed = JSON.parse(raw);
  if (!parsed.data) {
    console.error("backup/keymap.json has no `data` field");
    process.exit(1);
  }

  const dev = WLDevice.open();
  if (!dev) {
    console.error("No device on the HID bus. Press a key to wake it, then re-run.");
    process.exit(1);
  }

  await dev.call("fs.write", { file: "keymap.json", data: parsed.data });
  const back = await dev.call("fs.read", { file: "keymap.json" });
  const rows = JSON.parse(typeof back === "string" ? back : back.data)
    .profiles[0].layers[0].layout.keymap;
  console.log("restored. layer 0 now:", JSON.stringify(rows));
  dev.close();
  process.exit(0);
}

main().catch((e) => {
  console.error("restore failed:", e.message);
  process.exit(1);
});
