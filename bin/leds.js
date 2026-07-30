#!/usr/bin/env node
"use strict";
// Long-running bridge: Herdr agent status -> Creator Micro 2 underglow.
//
// `lights.preview` addresses two whole-device surfaces - `backlight` (under the
// keys) and `underglow` - with one colour each. There is no per-key addressing
// available to the host: the firmware also registers `v.oai.rgbcfg`, whose
// vocabulary includes `keys`/`ambient` sections, but on the Creator Micro 2
// variant that handler is inert (it answers {"ok":1} and changes nothing, as
// confirmed on firmware v0.6.0-rc.10). The device's own keymap.json likewise
// persists lighting as exactly those two surfaces.
//
// So the light carries an aggregate "does anything need me?" signal across all
// agents: worst state wins.
//
// Liveness comes from three places, so a missed event can never leave the
// light stale:
//   1. a lifecycle event stream (panes appearing/disappearing/gaining agents)
//   2. one status stream per agent pane (instant status transitions)
//   3. a slow poll of agent.list as a backstop
// agent.list is always the source of truth; events only decide *when* to look.

const fs = require("node:fs");
const path = require("node:path");
const { WLDevice, PermissionError } = require("../lib/wl-device.js");
const { EventStream, listAgents } = require("../lib/herdr-client.js");
const { DEFAULTS, aggregate, lightingFor, mergeConfig } = require("../lib/status.js");

const log = (...a) => console.log(new Date().toISOString(), ...a);

function loadConfig() {
  const dir = process.env.HERDR_PLUGIN_CONFIG_DIR;
  if (!dir) return DEFAULTS;
  try {
    return mergeConfig(
      JSON.parse(fs.readFileSync(path.join(dir, "config.json"), "utf8")),
    );
  } catch {
    return DEFAULTS;
  }
}

class Bridge {
  constructor(cfg) {
    this.cfg = cfg;
    this.device = null;
    this.lifecycle = null;
    this.statusStreams = new Map(); // pane_id -> EventStream
    this.lastState = undefined;
    this.debounce = null;
    this.stopped = false;
  }

  async start() {
    // A Bluetooth pad sleeps when idle and vanishes from the HID bus, so a
    // missing device at startup is normal, not fatal. Permission problems are
    // fatal, because no amount of waiting fixes them.
    try {
      await this.openDevice();
    } catch (err) {
      if (err instanceof PermissionError) throw err;
      log(`${err.message} - waiting for it to appear`);
      this.reopenLater();
    }
    this.startLifecycleStream();
    await this.refresh();
    this.poll = setInterval(() => this.refresh(), this.cfg.poll_ms);
  }

  async openDevice() {
    const dev = WLDevice.open();
    if (!dev) throw new Error("no Work Louder device found");
    this.device = dev;
    dev.onClose = () => {
      log("device disconnected");
      this.device = null;
      this.lastState = undefined;
      this.reopenLater();
    };
    let version;
    try {
      version = await dev.version();
    } catch {
      /* lighting still works even if sys.version is unsupported */
    }
    log(
      `device: ${dev.info.product} (${dev.model})` +
        (version ? ` firmware ${JSON.stringify(version)}` : ""),
    );
  }

  reopenLater() {
    if (this.stopped) return;
    setTimeout(() => {
      if (this.stopped || this.device) return;
      this.openDevice()
        .then(() => {
          log("device back");
          this.lastState = undefined;
          return this.refresh();
        })
        .catch((err) => {
          // Report a permission problem once rather than every retry, but keep
          // retrying so granting it later just starts working.
          if (err instanceof PermissionError && !this.warnedPermission) {
            this.warnedPermission = true;
            log(err.message);
          }
          this.reopenLater();
        });
    }, 3000);
  }

  startLifecycleStream() {
    if (this.stopped) return;
    const stream = new EventStream([
      { type: "pane.created" },
      { type: "pane.closed" },
      { type: "pane.exited" },
      { type: "pane.agent_detected" },
    ]).start();
    stream.on("ready", () => log("watching herdr pane lifecycle"));
    stream.on("event", () => this.schedule());
    stream.on("error", (err) => log("lifecycle subscribe failed:", err.message));
    stream.on("closed", () => {
      if (this.stopped) return;
      this.lifecycle = null;
      setTimeout(() => this.startLifecycleStream(), 2000);
    });
    this.lifecycle = stream;
  }

  // One dedicated stream per agent pane, since a subscription owns its
  // connection and cannot be extended after the fact.
  reconcileStatusStreams(agents) {
    const wanted = new Set(agents.map((a) => a.pane_id).filter(Boolean));
    for (const [paneId, stream] of this.statusStreams) {
      if (!wanted.has(paneId)) {
        stream.stop();
        this.statusStreams.delete(paneId);
      }
    }
    for (const paneId of wanted) {
      if (this.statusStreams.has(paneId)) continue;
      const stream = new EventStream([
        { type: "pane.agent_status_changed", pane_id: paneId },
      ]).start();
      stream.on("event", () => this.schedule());
      stream.on("closed", () => {
        if (this.statusStreams.get(paneId) === stream)
          this.statusStreams.delete(paneId);
      });
      stream.on("error", () => {});
      this.statusStreams.set(paneId, stream);
    }
  }

  schedule() {
    if (this.debounce) return;
    this.debounce = setTimeout(() => {
      this.debounce = null;
      this.refresh();
    }, this.cfg.debounce_ms);
  }

  async refresh() {
    if (this.stopped) return;
    let agents;
    try {
      agents = await listAgents();
    } catch (err) {
      log("agent.list failed:", err.message);
      return;
    }
    this.reconcileStatusStreams(agents);
    const state = aggregate(agents, this.cfg);
    if (state === this.lastState) return;
    this.lastState = state;
    await this.apply(state, agents);
  }

  async apply(state, agents) {
    if (!this.device) return;
    const side = lightingFor(state, this.cfg);
    const payload = { underglow: side };
    if (this.cfg.drive_backlight) payload.backlight = side;
    try {
      await this.device.setLighting(payload);
      const summary =
        agents.map((a) => `${a.agent}:${a.agent_status}`).join(" ") || "none";
      log(`${state ?? "no agents"} -> ${side ? side.color : "off"}  [${summary}]`);
    } catch (err) {
      log("lights.preview failed:", err.message);
      this.lastState = undefined; // retry on the next tick
    }
  }

  async stop() {
    this.stopped = true;
    clearInterval(this.poll);
    if (this.lifecycle) this.lifecycle.stop();
    for (const s of this.statusStreams.values()) s.stop();
    if (this.device) {
      try {
        await this.device.setLighting({ underglow: null });
      } catch {
        /* best effort */
      }
      this.device.close();
    }
  }
}

async function main() {
  const bridge = new Bridge(loadConfig());
  const shutdown = async () => {
    await bridge.stop();
    process.exit(0);
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
  try {
    await bridge.start();
  } catch (err) {
    if (err instanceof PermissionError) {
      console.error("\n" + err.message + "\n");
      process.exit(2);
    }
    console.error("failed to start:", err.message);
    process.exit(1);
  }
}

main();
