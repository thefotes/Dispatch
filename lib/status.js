"use strict";
// Pure mapping from a set of Herdr agents to a single lighting state.
//
// The Creator Micro 2 has one controllable light, so the mapping is
// worst-state-wins across every agent: the light answers "does anything need
// me?" rather than describing any individual agent.

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
  // The pad exposes two independently addressable surfaces and honours both,
  // so drive them together: the key backlight is the one you actually catch
  // out of the corner of your eye, the underglow is the ambient wash.
  drive_backlight: true,
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

function mergeConfig(raw) {
  if (!raw || typeof raw !== "object") return DEFAULTS;
  return {
    ...DEFAULTS,
    ...raw,
    colors: { ...DEFAULTS.colors, ...(raw.colors || {}) },
    effect: { ...DEFAULTS.effect, ...(raw.effect || {}) },
  };
}

module.exports = { DEFAULTS, aggregate, lightingFor, mergeConfig };
