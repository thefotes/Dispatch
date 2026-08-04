#!/usr/bin/env node
"use strict";
// Focus the Nth agent in Herdr. Bound to the top six keys of the macro pad.
//
// Slot order is stable (workspace, then tab, then pane) so a given key keeps
// pointing at the same agent for as long as the set of agents is unchanged.

const { listAgents, focusAgent } = require("../lib/herdr-client.js");

async function main() {
  const slot = parseInt(process.argv[2], 10);
  if (!Number.isInteger(slot) || slot < 1) {
    console.error("usage: focus.js <slot-number>");
    process.exit(64);
  }

  let agents;
  try {
    agents = await listAgents();
  } catch (err) {
    console.error(err.message);
    process.exit(1);
  }

  const agent = agents[slot - 1];
  if (!agent) {
    console.error(`no agent in slot ${slot} (${agents.length} running)`);
    process.exit(3);
  }

  try {
    // Pane id first: `agent.focus` resolves pane ids only, and answers
    // `agent_not_found` for a terminal id (Herdr 0.7.5).
    await focusAgent(agent.pane_id || agent.terminal_id);
  } catch (err) {
    console.error(err.message);
    process.exit(1);
  }
  console.log(
    `slot ${slot} -> ${agent.agent} (${agent.agent_status}) ${agent.pane_id} ${agent.cwd || ""}`,
  );
}

main();
