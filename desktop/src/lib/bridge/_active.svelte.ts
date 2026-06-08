// Shared cross-store reactive state. Lives here so peer stores
// (agents, package, ws, agent_settings) can read it without
// importing each other — which would create static cycles fallow
// flags as init-order risk + tree-shaking blockers.
//
// Pattern: the *owning* store (agents, package) writes here when its
// selection changes; the *consumer* (ws.sendUserInput) reads from
// here. No store imports another.
//
// Naming: `active` because what's here is the *currently-selected*
// runtime state every command needs to ground itself in. Today
// that's two fields; future additions go here, not in new
// cross-imports.

class Active {
  /** Selected agent's slug. `null` until the agents store loads
   *  + a selection is made; ws.sendUserInput falls back to its
   *  hard-coded default in that case. */
  agentSlug = $state<string | null>(null);

  /** First folder of the active Package (the workdir the daemon
   *  runs sessions in). `null` when no Package is active. */
  workdir = $state<string | null>(null);
}

export const active = new Active();
