#!/usr/bin/env node
"use strict";
// Test the strongest remaining hypothesis for per-key colour:
//
//   v.oai.thstatus is registered on the Creator Micro 2 (it answers {"ok":1}
//   rather than "Method not found") but has no visible effect. The OAI bridge
//   logs syncKeysLighting/syncAmbientLighting, and the firmware's keycode table
//   contains KV_OAI_AG00..AG19. So the bridge may only colour keys that are
//   actually BOUND to KV_OAI_AG* keycodes - and this pad's keymap is all KC_F13
//   ..KC_F24, giving it nothing to light.
//
// So: bind the top six keys to KV_OAI_AG00..AG05, drive thstatus, and watch.
// The original keymap is restored on every exit path, including Ctrl-C.

const fs = require("node:fs");
const path = require("node:path");
const { WLDevice } = require("../lib/wl-device.js");

const BACKUP = path.join(__dirname, "..", "backup", "keymap.json");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function buildOaiKeymap(originalFileContent) {
  const file = JSON.parse(originalFileContent);
  const cfg = JSON.parse(file.data);
  const layer = cfg.profiles[0].layers[0];
  // Rows are [2, 4, 4, 3]; the top six keys are rows 0 and 1.
  layer.layout.keymap[0] = ["KV_OAI_AG00", "KV_OAI_AG01"];
  layer.layout.keymap[1] = ["KV_OAI_AG02", "KV_OAI_AG03", "KV_OAI_AG04", "KV_OAI_AG05"];
  return { file: { ...file, data: JSON.stringify(cfg) }, cfg };
}

async function restore(dev, originalFileContent) {
  const parsed = JSON.parse(originalFileContent);
  await dev.call("fs.write", { file: "keymap.json", data: parsed.data });
}

async function main() {
  const original = fs.readFileSync(BACKUP, "utf8");
  if (!original.includes("KC_F13")) {
    console.error("backup does not look like your keymap; aborting");
    process.exit(1);
  }

  const dev = WLDevice.open();
  if (!dev) {
    console.error("No device on the HID bus. Press a key to wake it.");
    process.exit(1);
  }

  let restored = false;
  const doRestore = async () => {
    if (restored) return;
    restored = true;
    try {
      await restore(dev, original);
      console.log("\n>>> original keymap restored (F13-F24 back)");
    } catch (err) {
      console.error(
        `\n!!! RESTORE FAILED: ${err.message}\n` +
          `!!! Re-run: node bin/restore-keymap.js`,
      );
    }
  };
  process.on("SIGINT", async () => { await doRestore(); process.exit(130); });

  try {
    console.log(`device: ${dev.info.product}`);
    console.log(`firmware: ${JSON.stringify(await dev.call("sys.version"))}\n`);

    const { file } = buildOaiKeymap(original);
    console.log("writing keymap with KV_OAI_AG00..AG05 on the top six keys...");
    await dev.call("fs.write", { file: "keymap.json", data: file.data });

    const back = await dev.call("fs.read", { file: "keymap.json" });
    const readCfg = JSON.parse(typeof back === "string" ? back : back.data);
    const rows = readCfg.profiles[0].layers[0].layout.keymap;
    console.log(`device now reports: ${JSON.stringify(rows[0])} ${JSON.stringify(rows[1])}`);
    if (!JSON.stringify(rows).includes("KV_OAI_AG00")) {
      console.log("!! firmware did not accept the OAI keycodes - hypothesis dead here");
      await doRestore();
      dev.close();
      process.exit(0);
    }
    console.log("firmware ACCEPTED the OAI keycodes.\n");

    console.log("Now watch the TOP SIX KEYS. Each step holds 6 seconds.\n");

    const shapes = [
      ["per-slot array", { status: [1, 2, 3, 4, 0, 1] }],
      ["bare array", [1, 2, 3, 4, 0, 1]],
      ["indexed objects", { status: [{ index: 0, status: 1 }, { index: 1, status: 2 }] }],
      ["agents key", { agents: [{ id: 0, status: 1 }, { id: 1, status: 2 }] }],
      ["single slot", { index: 0, status: 1 }],
      ["act array", { act: [1, 2, 3, 4, 0, 1] }],
      ["ag map", { ag: { 0: 1, 1: 2, 2: 3, 3: 4, 4: 0, 5: 1 } }],
      ["all thinking", { status: [2, 2, 2, 2, 2, 2] }],
    ];

    for (const [label, params] of shapes) {
      console.log(`>>> thstatus ${label}: ${JSON.stringify(params).slice(0, 70)}`);
      console.log("    LOOK: do any of the top six keys light up / differ?");
      try {
        await dev.call("v.oai.thstatus", params);
      } catch (err) {
        console.log(`    (device said: ${err.message})`);
      }
      await sleep(6000);
    }

    // The bridge may need the backlight surface active before it can paint.
    console.log("\n>>> same again, but with the key backlight switched on first");
    await dev.call("lights.preview", {
      backlight: { effect: "solid", brightness: 1, speed: 0.5, magic: 1, color: 0x101010 },
    }).catch(() => {});
    for (const [label, params] of shapes.slice(0, 3)) {
      console.log(`>>> backlight-on + thstatus ${label}`);
      console.log("    LOOK: do individual keys take different colours?");
      try {
        await dev.call("v.oai.thstatus", params);
      } catch (err) {
        console.log(`    (device said: ${err.message})`);
      }
      await sleep(6000);
    }
  } finally {
    await doRestore();
    try {
      await dev.call("lights.preview", {
        backlight: { effect: "off", brightness: 0, speed: 0.5, magic: 1, color: 0 },
      });
    } catch {}
    dev.close();
  }
  process.exit(0);
}

main().catch(async (e) => {
  console.error("failed:", e.message);
  process.exit(1);
});
