// The org/nexus identity store — "which orgs am I in, and my role?" Loaded from the
// cloud control plane's GET /api/platform/me (authed by the WorkOS session JWT). An
// org ≈ a nexus (the isolation unit), so this feeds the titlebar org/nexus switcher:
// Personal + each organization you've been added to, with your role.
//
// Fail-soft: no session / offline / no WorkOS key on the control plane ⇒ just Personal.
// The control-plane URL is overridable via PUBLIC_NEXUS_CP_URL.

import { cloudClient } from "$lib/rcp/providers/workos";
import { auth } from "$lib/auth/store.svelte";

const CP_URL =
  (typeof import.meta !== "undefined" &&
    (import.meta as { env?: Record<string, string> }).env?.PUBLIC_NEXUS_CP_URL) ||
  "https://wb-nexus-cp.fly.dev";

export type OrgNexus = { id: string; name: string; role: string };
export type SwitcherEntry = OrgNexus & { personal: boolean };

class Orgs {
  /** Orgs the user belongs to (each ≈ a nexus), from the control plane. */
  list = $state<OrgNexus[]>([]);
  user = $state<{ id: string; name: string } | null>(null);
  /** The org of the current session token (the "active" one). */
  activeOrg = $state<string | null>(null);
  loaded = $state(false);

  /** Personal + every org you belong to (each ≈ a nexus). Personal is always first. */
  get switcher(): SwitcherEntry[] {
    const personal: SwitcherEntry = { id: "personal", name: "Personal", role: "owner", personal: true };
    return [personal, ...this.list.map((o) => ({ ...o, personal: false }))];
  }

  /** Load from the cloud once (idempotent). Signed-out ⇒ Personal only. */
  async load(force = false): Promise<void> {
    if (this.loaded && !force) return;
    this.loaded = true;
    if (!auth.user) return; // not signed in → Personal only, no cloud call
    try {
      const me = await cloudClient(CP_URL, auth.brokerUrl).request<{
        user: { id: string; name: string } | null;
        active_org: string | null;
        orgs: OrgNexus[];
      }>("/api/platform/me", { timeoutMs: 12_000 });
      this.user = me.user ?? null;
      this.activeOrg = me.active_org ?? null;
      this.list = Array.isArray(me.orgs) ? me.orgs : [];
    } catch {
      this.list = []; // fail-soft — Personal still works offline
    }
  }
}

export const orgs = new Orgs();
