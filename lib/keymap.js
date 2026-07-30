"use strict";
// Device keymap handling.
//
// Per-key lighting only works on keys bound to KV_OAI_AG* keycodes, and only
// when those bindings are on the ACTIVE layer. Parking them on a spare layer
// does nothing. This was worth pinning down because nothing reports the
// mismatch: `v.oai.thstatus` still answers {"ok":1} for a key that cannot be
// lit, so a wrong keymap looks exactly like a working one from the host side.
//
// The trade-off: an AG-bound key emits nothing the host can see — no keystroke,
// and no `v.oai.hid` notification on this variant. A key is either a status
// light or an input, not both.

const AG_CODES = ["KV_OAI_AG00", "KV_OAI_AG01", "KV_OAI_AG02", "KV_OAI_AG03", "KV_OAI_AG04", "KV_OAI_AG05"];

// Rows are [2, 4, 4, 3]; the six agent keys are rows 0 and 1.
const AGENT_ROWS = [
  { row: 0, codes: AG_CODES.slice(0, 2) },
  { row: 1, codes: AG_CODES.slice(2, 6) },
];

function parseKeymapFile(raw) {
  const file = typeof raw === "string" ? JSON.parse(raw) : raw;
  const data = typeof file.data === "string" ? file.data : JSON.stringify(file.data);
  return { file, config: JSON.parse(data) };
}

function activeLayer(config) {
  const profile = config.profiles?.[config.activeProfileId ?? 0] ?? config.profiles?.[0];
  if (!profile) throw new Error("keymap has no profiles");
  // `layer_index` from device.status is 1-based against this list.
  return profile.layers?.[0];
}

async function readKeymap(dev) {
  const raw = await dev.call("fs.read", { file: "keymap.json" });
  return parseKeymapFile(raw);
}

/// True when the six agent keys are bound to AG keycodes on the active layer.
function isAgentKeymapApplied(config) {
  const layer = activeLayer(config);
  if (!layer) return false;
  return AGENT_ROWS.every(({ row, codes }) => {
    const actual = layer.layout?.keymap?.[row];
    return Array.isArray(actual) && codes.every((code, i) => actual[i] === code);
  });
}

/// Bind the six agent keys to AG keycodes, leaving every other key, layer,
/// encoder, joystick and lighting setting untouched.
function withAgentKeymap(config) {
  const next = JSON.parse(JSON.stringify(config));
  const layer = activeLayer(next);
  if (!layer) throw new Error("keymap has no layers");
  for (const { row, codes } of AGENT_ROWS) {
    const existing = layer.layout.keymap[row] || [];
    layer.layout.keymap[row] = codes.map((code, i) => (i < existing.length ? code : code));
  }
  return next;
}

async function applyAgentKeymap(dev) {
  const { config } = await readKeymap(dev);
  if (isAgentKeymapApplied(config)) return { changed: false, config };
  const next = withAgentKeymap(config);
  await dev.call("fs.write", { file: "keymap.json", data: JSON.stringify(next) });
  const after = await readKeymap(dev);
  if (!isAgentKeymapApplied(after.config)) {
    throw new Error("device did not accept the agent keymap");
  }
  return { changed: true, config: after.config };
}

module.exports = {
  AG_CODES,
  AGENT_ROWS,
  parseKeymapFile,
  activeLayer,
  readKeymap,
  isAgentKeymapApplied,
  withAgentKeymap,
  applyAgentKeymap,
};
