"use strict";
// The Work Louder OAI vendor lighting API.
//
// Recovered from @worklouder/device-kit-oai, which ships inside the Codex
// desktop app. Two things make this API invisible from the outside, and both
// are why earlier guesses at the schema silently no-op'd:
//
//   1. Field names are abbreviated on the wire (e, b, s, m, c), not the full
//      names that `lights.preview` uses.
//   2. `effect` is a NUMBER here (0..6), not one of the effect strings that
//      `lights.preview` accepts.
//
// The firmware answers {"ok":1} regardless, so a wrong shape is indistinguishable
// from a right one except by looking at the LEDs.

// v.oai.thstatus -- per-thread lighting. This is the per-key channel: each
// "thread" maps to one of the device's agent-group keys.
const M_THREADS = "v.oai.thstatus";
// v.oai.rgbcfg -- the two zone surfaces, under OAI names.
const M_RGBCFG = "v.oai.rgbcfg";

// Device -> host notifications (not callable methods).
const N_HID = "v.oai.hid";
const N_JOYSTICK = "v.oai.rad";

const EFFECT = {
  off: 0,
  solid: 1,
  snake: 2,
  rainbow: 3,
  breath: 4,
  gradient: 5,
  shallowBreath: 6,
};

function toColorInt(color) {
  if (typeof color !== "string") return color;
  let h = color.replace("#", "");
  if (h.length === 3) h = h.split("").map((c) => c + c).join("");
  return parseInt(h, 16);
}

function resolveEffect(effect) {
  if (typeof effect === "number") return effect;
  if (effect in EFFECT) return EFFECT[effect];
  throw new Error(`unknown lighting effect: ${effect}`);
}

// One zone: {effect, brightness, speed, magic, color} -> {e, b, s, m, c}
function minimizeSide(side) {
  return {
    e: resolveEffect(side.effect ?? "solid"),
    b: side.brightness === undefined ? 1 : side.brightness,
    s: side.speed === undefined ? 0.5 : side.speed,
    m: side.magic === undefined ? 1 : side.magic,
    c: toColorInt(side.color ?? 0),
  };
}

// One thread. Only `id` is required; omitted fields stay unchanged on device.
function minimizeThread(t) {
  const out = { id: t.id };
  if (t.color !== undefined) out.c = toColorInt(t.color);
  if (t.brightness !== undefined) out.b = t.brightness;
  if (t.effect !== undefined) out.e = resolveEffect(t.effect);
  if (t.speed !== undefined) out.s = t.speed;
  if (t.syncKeysLighting !== undefined) out.sk = t.syncKeysLighting ? 1 : 0;
  if (t.syncAmbientLighting !== undefined) out.sa = t.syncAmbientLighting ? 1 : 0;
  return out;
}

// threads: [{id, color?, brightness?, effect?, speed?, syncKeysLighting?, syncAmbientLighting?}]
// Note the params are a bare ARRAY, not an object.
function sendThreadsLighting(dev, threads) {
  return dev.call(M_THREADS, threads.map(minimizeThread));
}

// config: {ambient: <side>, keys: <side>}
function sendLightingConfig(dev, config) {
  return dev.call(M_RGBCFG, {
    ambient: minimizeSide(config.ambient),
    keys: minimizeSide(config.keys),
  });
}

// The device has 13 keys, but the firmware's keycode table goes to AG19, so
// clear the whole id space rather than just the visible keys.
const MAX_THREAD_ID = 19;

// Turn everything off. Thread state overrides the zones, so clearing the zones
// alone leaves the pad lit - both have to go.
async function allLightsOff(dev) {
  await sendThreadsLighting(
    dev,
    Array.from({ length: MAX_THREAD_ID + 1 }, (_, id) => ({
      id,
      brightness: 0,
      effect: "off",
      syncKeysLighting: false,
      syncAmbientLighting: false,
    })),
  );
  const dark = { effect: "off", brightness: 0, speed: 0.5, magic: 1, color: 0 };
  await sendLightingConfig(dev, { keys: dark, ambient: dark });
}

// Attach handlers for device-pushed events. Returns a detach function.
function onNotify(dev, { onKey, onJoystick } = {}) {
  const prev = dev.onNotify;
  dev.onNotify = (method, params) => {
    if (method === N_HID && onKey) {
      onKey({ key: params?.k, act: params?.act, agent: params?.ag });
    } else if (method === N_JOYSTICK && onJoystick) {
      onJoystick({ angle: params?.a, distance: params?.d });
    }
    if (prev) prev(method, params);
  };
  return () => {
    dev.onNotify = prev;
  };
}

module.exports = {
  EFFECT,
  MAX_THREAD_ID,
  allLightsOff,
  M_THREADS,
  M_RGBCFG,
  N_HID,
  N_JOYSTICK,
  minimizeSide,
  minimizeThread,
  sendThreadsLighting,
  sendLightingConfig,
  onNotify,
  toColorInt,
};
