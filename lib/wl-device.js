"use strict";
// Work Louder raw-HID JSON-RPC transport.
//
// Protocol (derived from the device's HID report descriptor and Work Louder's
// own device kit): the device exposes a vendor-defined collection on usage
// page 0xFF00 / usage 1 carrying 64-byte reports.
//
//   byte 0      report id, always 0x06
//   byte 1      channel: 1 = firmware debug log, 2 = JSON-RPC
//   byte 2      payload length in this report, <= 61
//   bytes 3..   UTF-8 fragment of a JSON-RPC 2.0 message
//
// Requests are JSON objects {method, params, id} split across as many reports
// as needed. Responses arrive the same way and are reassembled by scanning for
// balanced top-level braces.

const HID = require("node-hid");

const WL_VID = 0x303a;
const RAW_USAGE_PAGE = 0xff00;
const RAW_USAGE = 1;
const REPORT_ID = 0x06;
const CH_DEBUG = 1;
const CH_RPC = 2;
const CHUNK = 61;
const RPC_TIMEOUT_MS = 8000;

// Product ids that speak this protocol.
const KNOWN_PIDS = new Map([
  [0x8294, "nomad_e"],
  [0x8295, "nomad_e"],
  [0x8296, "knob"],
  [0x8297, "creator_micro_v2"],
  [0x8298, "creator_micro_v2"],
  [0x82e3, "knob"],
  [0x8346, "xyz"],
  [0x8360, "codex_micro"],
  [0x8370, "nomad_e_v2"],
  [0x8371, "nomad_e_v2"],
  [0x8396, "knob_f1"],
  [0x8397, "knob_f1"],
]);

class PermissionError extends Error {}

function findRawInterface() {
  let devices;
  try {
    devices = HID.devices();
  } catch (err) {
    throw new Error(`HID enumeration failed: ${err.message}`);
  }
  return (
    devices.find(
      (d) =>
        d.vendorId === WL_VID &&
        d.usagePage === RAW_USAGE_PAGE &&
        d.usage === RAW_USAGE,
    ) || null
  );
}

class WLDevice {
  constructor(info) {
    this.info = info;
    this.model = KNOWN_PIDS.get(info.productId) || "unknown";
    this.dev = null;
    this.pending = new Map();
    this.accum = "";
    this.onDebug = null;
    this.onClose = null;
    this.onNotify = null;
  }

  // Set WL_FAKE_DEVICE=1 to exercise the full Herdr -> color pipeline without
  // hardware; lighting calls are logged instead of written.
  static open() {
    if (process.env.WL_FAKE_DEVICE) return new FakeDevice();
    const info = findRawInterface();
    if (!info) return null;
    const dev = new WLDevice(info);
    dev._open();
    return dev;
  }

  _open() {
    try {
      // hidapi seizes the device by default. This pad puts its vendor
      // collection on the same IOHIDDevice as its keyboard collection, and
      // macOS refuses to let anyone seize a keyboard (0xE00002C1), so open
      // shared. This also lets Work Louder's Input app keep the device open.
      this.dev = new HID.HID(this.info.path, { nonExclusive: true });
    } catch (err) {
      const msg = String(err.message || err);
      if (/privilege violation|not permitted|access denied/i.test(msg)) {
        throw new PermissionError(
          "macOS denied access to the Work Louder HID interface (" +
            msg +
            ").\nInput Monitoring for your terminal may be missing: System " +
            "Settings > Privacy & Security > Input Monitoring.",
        );
      }
      throw err;
    }
    this.dev.on("data", (buf) => this._onReport(buf));
    this.dev.on("error", (err) => this._fail(err));
  }

  _fail(err) {
    for (const [, p] of this.pending) {
      clearTimeout(p.timer);
      p.reject(err instanceof Error ? err : new Error(String(err)));
    }
    this.pending.clear();
    if (this.onClose) {
      const cb = this.onClose;
      this.onClose = null;
      cb(err);
    }
  }

  // node-hid may or may not include the report id as byte 0 depending on how
  // the OS presents numbered reports, so accept whichever alignment yields a
  // valid channel and length.
  _onReport(buf) {
    if (!this._tryFrame(buf, 1)) this._tryFrame(buf, 0);
  }

  _tryFrame(buf, off) {
    const channel = buf[off];
    const len = buf[off + 1];
    if (channel !== CH_DEBUG && channel !== CH_RPC) return false;
    if (len === undefined || len > CHUNK) return false;
    const text = buf.slice(off + 2, off + 2 + len).toString("utf8");
    if (channel === CH_DEBUG) {
      if (this.onDebug) this.onDebug(text);
      return true;
    }
    this._feedRpc(text);
    return true;
  }

  _feedRpc(text) {
    this.accum += text;
    let depth = 0;
    let start = -1;
    let inStr = false;
    let esc = false;
    for (let i = 0; i < this.accum.length; i++) {
      const c = this.accum[i];
      if (inStr) {
        if (esc) esc = false;
        else if (c === "\\") esc = true;
        else if (c === '"') inStr = false;
        continue;
      }
      if (c === '"') {
        inStr = true;
      } else if (c === "{") {
        if (depth === 0) start = i;
        depth++;
      } else if (c === "}") {
        if (depth === 0) continue;
        depth--;
        if (depth === 0 && start >= 0) {
          const raw = this.accum.slice(start, i + 1);
          this.accum = this.accum.slice(i + 1);
          i = -1;
          start = -1;
          try {
            this._dispatch(JSON.parse(raw));
          } catch {
            /* ignore malformed frame */
          }
        }
      }
    }
    // Don't let a desynchronised stream grow without bound.
    if (this.accum.length > 8192) this.accum = "";
  }

  _dispatch(obj) {
    // Notifications use an abbreviated envelope - {"m": method, "p": params} -
    // while responses use the full "method". Miss that and key presses look
    // like they are never sent.
    const method = obj.m !== undefined ? obj.m : obj.method;
    const params = obj.m !== undefined ? obj.p : obj.params;
    if (method !== undefined && obj.id === undefined) {
      if (this.onNotify) this.onNotify(method, params);
      return;
    }
    const key = String(obj.id);
    const p = this.pending.get(key);
    if (!p) return;
    this.pending.delete(key);
    clearTimeout(p.timer);
    if (obj.error) p.reject(new Error(obj.error.message || "rpc error"));
    else p.resolve(obj.result);
  }

  call(method, params = null) {
    if (!this.dev) return Promise.reject(new Error("device not open"));
    // Firmware only accepts ids in [0, 999).
    const id = Math.floor(Math.random() * 999);
    const payload = Buffer.from(JSON.stringify({ method, params, id }), "utf8");
    for (let off = 0; off < payload.length; off += CHUNK) {
      const n = Math.min(CHUNK, payload.length - off);
      const report = Buffer.alloc(64);
      report[0] = REPORT_ID;
      report[1] = CH_RPC;
      report[2] = n;
      payload.copy(report, 3, off, off + n);
      this.dev.write(Array.from(report));
    }
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(String(id));
        reject(new Error(`timeout waiting for ${method}`));
      }, RPC_TIMEOUT_MS);
      this.pending.set(String(id), { resolve, reject, timer });
    });
  }

  version() {
    return this.call("sys.version");
  }

  status() {
    return this.call("device.status");
  }

  // `lights.preview` is the only lighting entry point the firmware exposes and
  // it addresses two whole-device surfaces, not individual keys. Colors go on
  // the wire as a 0xRRGGBB integer; brightness/speed/magic are 0..1 floats.
  setLighting({ backlight, underglow }) {
    const side = (s) =>
      s === null
        ? { effect: "off", brightness: 0, speed: 0.5, magic: 1, color: 0 }
        : {
            effect: s.effect || "solid",
            brightness: s.brightness === undefined ? 1 : s.brightness,
            speed: s.speed === undefined ? 0.5 : s.speed,
            magic: s.magic === undefined ? 1 : s.magic,
            color: typeof s.color === "string" ? hexToInt(s.color) : s.color,
          };
    const params = {};
    if (backlight !== undefined) params.backlight = side(backlight);
    if (underglow !== undefined) params.underglow = side(underglow);
    return this.call("lights.preview", params);
  }

  close() {
    if (!this.dev) return;
    try {
      this.dev.close();
    } catch {
      /* already gone */
    }
    this.dev = null;
  }
}

class FakeDevice {
  constructor() {
    this.info = { product: "Creator Micro 2 (fake)", path: "fake" };
    this.model = "creator_micro_v2";
    this.onClose = null;
    this.onDebug = null;
  }
  version() {
    return Promise.resolve("fake");
  }
  status() {
    return Promise.resolve({ battery: 100 });
  }
  setLighting(payload) {
    const show = (s) =>
      s === null || s === undefined
        ? "off"
        : `${s.effect} #${(typeof s.color === "string" ? hexToInt(s.color) : s.color)
            .toString(16)
            .toUpperCase()
            .padStart(6, "0")} @${s.brightness}`;
    const parts = Object.entries(payload).map(([k, v]) => `${k}=${show(v)}`);
    console.log("  [fake device] lights.preview " + parts.join(" "));
    return Promise.resolve(true);
  }
  close() {}
}

function hexToInt(hex) {
  let h = String(hex).replace("#", "");
  if (h.length === 3)
    h = h
      .split("")
      .map((c) => c + c)
      .join("");
  return parseInt(h, 16);
}

module.exports = { WLDevice, PermissionError, findRawInterface, hexToInt, WL_VID };
