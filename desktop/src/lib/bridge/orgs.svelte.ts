// The org/nexus identity store — "which orgs am I in, and my role?" Loaded from the
// cloud control plane's GET /api/platform/me (authed by the WorkOS session JWT). An
// org ≈ a nexus (the isolation unit), so this feeds the titlebar org/nexus switcher:
// Personal + each organization you've been added to, with your role.
//
// Fail-soft: no session / offline / no WorkOS key on the control plane ⇒ just Personal.
// The control-plane URL is overridable via PUBLIC_NEXUS_CP_URL.

import { cloudClientReadOnly } from "$lib/rcp/providers/workos";
import { auth } from "$lib/auth/store.svelte";
import { nexus } from "$lib/bridge/nexus.svelte";

const CTX_KEY = "wb-active-context";
function restoreContext(): string {
  try {
    return (typeof localStorage !== "undefined" && localStorage.getItem(CTX_KEY)) || "personal";
  } catch {
    return "personal";
  }
}

const CP_URL =
  (typeof import.meta !== "undefined" &&
    (import.meta as { env?: Record<string, string> }).env?.PUBLIC_NEXUS_CP_URL) ||
  "https://wb-nexus-cp.fly.dev";

export type OrgNexus = { id: string; name: string; role: string };
export type SwitcherEntry = OrgNexus & {
  personal: boolean;
  /** A single glyph/emoji representing the nexus (Personal gets a default). */
  icon: string;
  /** One-word context shown under the name: "local" (Personal) or "cloud". */
  subtitle: string;
};

class Orgs {
  /** Orgs the user belongs to (each ≈ a nexus), from the control plane. */
  list = $state<OrgNexus[]>([]);
  user = $state<{ id: string; name: string } | null>(null);
  loaded = $state(false);

  /** Which nexus you're working in — "personal" (local) or an org id. Local UI state,
   *  persisted; Personal is the default. Switching is a context change, NOT a re-login. */
  activeContext = $state<string>(restoreContext());

  /** Personal + every org you belong to (each ≈ a nexus). Personal is always first.
   *  Personal = your local machine ("local"); orgs are hosted ("cloud"). */
  get switcher(): SwitcherEntry[] {
    const personal: SwitcherEntry = {
      id: "personal",
      name: "Personal",
      role: "owner",
      personal: true,
      icon: "💻",
      subtitle: "local"
    };
    return [
      personal,
      ...this.list.map((o) => ({ ...o, personal: false, icon: "☁️", subtitle: "cloud" }))
    ];
  }

  /** The currently-active entry (Personal when no org is active). Drives the chip. */
  get activeEntry(): SwitcherEntry {
    const all = this.switcher;
    return all.find((e) => this.isActive(e)) ?? all[0];
  }

  /** Whether `entry` is the nexus you're currently working in. */
  isActive(entry: SwitcherEntry): boolean {
    return entry.id === this.activeContext;
  }

  /**
   * Switch which nexus you're in. Personal = your local machine — free, offline, and
   * NO sign-in (you already signed into your account once). Orgs are hosted nexuses you
   * belong to. Switching is a context change, never a re-login.
   */
  switchTo(entry: SwitcherEntry): void {
    if (this.isActive(entry)) return;
    this.activeContext = entry.id;
    try {
      localStorage.setItem(CTX_KEY, entry.id);
    } catch {
      // ignore (SSR / private mode)
    }
    if (entry.personal) nexus.select("local");
    // Connecting to an org's hosted nexus is wired separately — no re-auth here.
  }

  /** Load from the cloud once (idempotent). Signed-out ⇒ Personal only. */
  async load(force = false): Promise<void> {
    if (this.loaded && !force) return;
    this.loaded = true;
    if (!auth.user) return; // not signed in → Personal only, no cloud call
    try {
      const me = await cloudClientReadOnly(CP_URL).request<{
        user: { id: string; name: string } | null;
        active_org: string | null;
        orgs: OrgNexus[];
      }>("/api/platform/me", { timeoutMs: 12_000 });
      this.user = me.user ?? null;
      this.list = Array.isArray(me.orgs) ? me.orgs : [];
    } catch {
      this.list = []; // fail-soft — Personal still works offline
    }
  }
}

export const orgs = new Orgs();
