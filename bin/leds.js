#!/usr/bin/env node
"use strict";
// Long-running bridge: Herdr agent status -> Creator Micro 2 lighting.
//
// Each agent gets its own key, plus an aggregate on the underglow.
//
// Keys are addressed through the vendor thread API (`v.oai.thstatus`), where a
// thread id is a key index, 0-based and row-major over the pad's [2,4,4,3]
// matrix. Agent slot N takes key N, so the six agent keys are ids 0..5 - the
// same physical keys that send F13..F18.
//
// The underglow keeps the worst-state-wins aggregate, because that is the part
// you can read from across the room without counting keys.
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
const { EventStream, listAgents, focusAgent } = require("../lib/herdr-client.js");
const { DEFAULTS, aggregate, lightingFor, threadsFor, mergeConfig } = require("../lib/status.js");
const { sendThreadsLighting, sendLightingConfig, allLightsOff, onNotify } = require("../lib/oai.js");
const { applyAgentKeymap, readKeymap, isAgentKeymapApplied } = require("../lib/keymap.js");

const OFF_SIDE = { effect: "off", brightness: 0, speed: 0.5, magic: 1, color: 0 };

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
    this.lastFingerprint = undefined;
    this.agents = [];
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
      this.lastFingerprint = undefined;
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

    // An AG key sends no keystroke; it reports itself over HID instead, as
    // {"m":"v.oai.hid","p":{"k":"AG01","act":1}}. So the key that shows an
    // agent's status is also the key that jumps to it.
    onNotify(dev, {
      onKey: (k) => {
        if (!k.pressed || k.index === null) return;
        this.focusSlot(k.index);
      },
    });

    // Per-key lighting only works on keys bound to KV_OAI_AG* on the active
    // layer, and nothing reports the mismatch: thstatus still answers
    // {"ok":1} for a key it cannot light. So check, rather than assume.
    if (this.cfg.manage_keymap) {
      try {
        const { changed } = await applyAgentKeymap(dev);
        log(changed ? "bound the six agent keys to KV_OAI_AG00..AG05" : "agent keymap already in place");
      } catch (err) {
        log(`could not apply the agent keymap: ${err.message}`);
        log("per-key colours will not work until the six keys are bound to KV_OAI_AG00..AG05");
      }
    } else {
      try {
        const { config } = await readKeymap(dev);
        if (!isAgentKeymapApplied(config)) {
          log("WARNING: the six agent keys are not bound to KV_OAI_AG00..AG05,");
          log("so per-key colours will silently do nothing. Run: node bin/apply-ag-keymap.js");
        }
      } catch {
        /* a keymap read failure is not worth aborting over */
      }
    }
  }

  // Key index N is agent slot N, the same mapping the lighting uses.
  async focusSlot(index) {
    const agent = this.agents[index];
    if (!agent) {
      log(`key ${index} pressed, but no agent in that slot`);
      return;
    }
    try {
      await focusAgent(agent.terminal_id || agent.pane_id);
      log(`key ${index} -> focused ${agent.agent} (${agent.agent_status}) ${agent.pane_id}`);
    } catch (err) {
      log(`key ${index} focus failed: ${err.message}`);
    }
  }

  reopenLater() {
    if (this.stopped) return;
    setTimeout(() => {
      if (this.stopped || this.device) return;
      this.openDevice()
        .then(() => {
          log("device back");
          this.lastFingerprint = undefined;
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
    this.agents = agents;
    this.reconcileStatusStreams(agents);
    const state = aggregate(agents, this.cfg);
    const threads = threadsFor(agents, this.cfg);
    // Compare the whole rendered picture, not just the aggregate, so a change
    // on one agent still repaints even when the worst state is unchanged.
    const fingerprint = JSON.stringify([state, threads]);
    if (fingerprint === this.lastFingerprint) return;
    this.lastFingerprint = fingerprint;
    await this.apply(state, threads, agents);
  }

  async apply(state, threads, agents) {
    if (!this.device) return;
    try {
      // Per-agent keys first, then the aggregate underglow.
      await sendThreadsLighting(this.device, threads);
      const side = lightingFor(state, this.cfg);
      await sendLightingConfig(this.device, {
        keys: this.cfg.drive_backlight && side ? side : OFF_SIDE,
        ambient: side ?? OFF_SIDE,
      });
      const summary =
        agents.map((a, i) => `${i + 1}:${a.agent_status}`).join(" ") || "none";
      log(`${state ?? "no agents"} | keys[${summary}]`);
    } catch (err) {
      log("lighting failed:", err.message);
      this.lastFingerprint = undefined; // repaint on the next tick
    }
  }

  async stop() {
    this.stopped = true;
    clearInterval(this.poll);
    if (this.lifecycle) this.lifecycle.stop();
    for (const s of this.statusStreams.values()) s.stop();
    if (this.device) {
      try {
        await allLightsOff(this.device);
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
