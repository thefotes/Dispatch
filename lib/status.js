"use strict";
// Pure mapping from a set of Herdr agents to device lighting.
//
// Keys are individually addressable through the vendor thread API, so each
// agent gets its own key. The underglow keeps the worst-state-wins aggregate,
// which is what you can see from across the room without reading six keys.

const DEFAULTS = {
  // Highest priority first: the first state present across all agents wins.
  priority: ["blocked", "working", "unknown", "idle", "done"],
  colors: {
    blocked: "#FF2D2D",
    working: "#FFA000",
    idle: "#00C853",
    done: "#00C853",
    unknown: "#00C853",
  },
  effect: {
    blocked: "breath",
    working: "solid",
    idle: "solid",
    done: "solid",
    unknown: "solid",
  },
  brightness: 1,
  speed: 0.5,
  // Leave the key-backlight ZONE alone: the keys are painted per-agent through
  // the thread API instead, and a zone colour would only compete with them.
  // Set true to wash the keys with the aggregate colour as well.
  drive_backlight: false,
  poll_ms: 2500,
  debounce_ms: 100,
};

// Returns the winning state name, or null when no agents are running.
function aggregate(agents, cfg = DEFAULTS) {
  if (!agents || !agents.length) return null;
  const present = new Set(agents.map((a) => a.agent_status));
  for (const state of cfg.priority) if (present.has(state)) return state;
  return "unknown";
}

// Returns the lighting payload for a state, or null to switch the light off.
function lightingFor(state, cfg = DEFAULTS) {
  if (state === null) return null;
  return {
    effect: cfg.effect[state] || "solid",
    color: cfg.colors[state] || "#FFFFFF",
    brightness: cfg.brightness,
    speed: cfg.speed,
    magic: 1,
  };
}

// Thread ids are key indices, 0-based and row-major over the pad's [2,4,4,3]
// matrix. So the top two rows - the six agent keys - are ids 0..5, which line
// up with the F13..F18 the same keys send.
const AGENT_KEY_IDS = [0, 1, 2, 3, 4, 5];

// One thread entry per agent key: agent slot N takes key N, unused keys go
// dark. Returns the array `sendThreadsLighting` expects.
function threadsFor(agents, cfg = DEFAULTS) {
  return AGENT_KEY_IDS.map((id, slot) => {
    const agent = agents[slot];
    if (!agent) return { id, brightness: 0, effect: "off" };
    const state = agent.agent_status;
    return {
      id,
      color: cfg.colors[state] || "#FFFFFF",
      brightness: cfg.brightness,
      effect: cfg.effect[state] || "solid",
      speed: cfg.speed,
    };
  });
}

function mergeConfig(raw) {
  if (!raw || typeof raw !== "object") return DEFAULTS;
  return {
    ...DEFAULTS,
    ...raw,
    colors: { ...DEFAULTS.colors, ...(raw.colors || {}) },
    effect: { ...DEFAULTS.effect, ...(raw.effect || {}) },
  };
}

module.exports = { DEFAULTS, AGENT_KEY_IDS, aggregate, lightingFor, threadsFor, mergeConfig };
