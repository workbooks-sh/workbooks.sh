// Nexus store (wb-aakl.9) — the browser's connection model.
//
// A "nexus" is a runtime the browser can talk to. There is always one
// zero-config entry: `local`, whose URL + token come live from the daemon
// discovery (the `sidecar` store, fed by runtime.json). The user can save
// additional REMOTE nexuses ({name, scheme, host, port, token}) and switch
// the active one; the RCP client (providers/tauri-local.ts) resolves its
// base URL + bearer from whichever nexus is active.
//
// "Nexus" is the product noun from day one (the runtime→nexus code rename
// is the separate wb-2phu). Remote tokens persist in localStorage for now;
// a later pass moves them to the OS keychain (the keys store) — noted so we
// don't ship secrets to disk long-term.

import { sidecar } from "./sidecar.svelte";

export type NexusMode = "local" | "remote";

/** How a nexus authenticates. `token` = static per-nexus bearer (or the
 *  local discovery token); `oidc` = the WorkOS keychain session (auto-renewing
 *  JWT via the cloudClient adapter). The cloud control plane is `oidc`. */
export type NexusAuth = "token" | "oidc";

export interface NexusEndpoint {
  id: string;
  name: string;
  /** Resolved base URL, e.g. https://nexus.example.com:4000. Empty for
   *  the local entry (it reads the live discovery URL instead). */
  url: string;
  /** Per-nexus bearer. Empty for local (reads the discovery token) and for
   *  oidc nexuses (the bearer comes from the WorkOS keychain session). */
  token: string;
  mode: NexusMode;
  /** Auth rung. Defaults to "token"; the cloud entry is "oidc". */
  auth?: NexusAuth;
}

/** Built-in cloud control-plane nexus. Always present, authenticates via the
 *  WorkOS keychain session (oidc) — after the user signs in, selecting this
 *  Just Works. URL overridable for dev via VITE_WB_CLOUD_NEXUS_URL. */
const CLOUD_ID = "cloud";
const CLOUD_URL =
  (import.meta.env as Record<string, string | undefined>)?.VITE_WB_CLOUD_NEXUS_URL ??
  "https://wb-nexus-cp.fly.dev";
const CLOUD_NEXUS: NexusEndpoint = {
  id: CLOUD_ID,
  name: "Workbooks Cloud",
  url: CLOUD_URL,
  token: "",
  mode: "remote",
  auth: "oidc",
};

export type NexusHealth = "ok" | "down" | "checking" | "unknown";

const STORE_KEY = "wb.nexus.v1";
const LOCAL_ID = "local";

function readSaved(): { remotes: NexusEndpoint[]; activeId: string } {
  if (typeof localStorage === "undefined") return { remotes: [], activeId: LOCAL_ID };
  try {
    const raw = localStorage.getItem(STORE_KEY);
    if (!raw) return { remotes: [], activeId: LOCAL_ID };
    const parsed = JSON.parse(raw);
    return {
      remotes: Array.isArray(parsed.remotes) ? parsed.remotes : [],
      activeId: typeof parsed.activeId === "string" ? parsed.activeId : LOCAL_ID,
    };
  } catch {
    return { remotes: [], activeId: LOCAL_ID };
  }
}

class NexusStore {
  /** User-saved remote nexuses (local is synthetic, prepended). */
  remotes = $state<NexusEndpoint[]>([]);
  activeId = $state<string>(LOCAL_ID);
  /** Health by endpoint id. Local mirrors the sidecar probe; remotes are
   *  probed on demand via /health. */
  health = $state<Record<string, NexusHealth>>({});

  constructor() {
    const saved = readSaved();
    this.remotes = saved.remotes;
    this.activeId = saved.activeId;
  }

  /** The local (zero-config) entry — its URL/token come live from the
   *  daemon discovery, so it stays correct across reboots. */
  get local(): NexusEndpoint {
    return {
      id: LOCAL_ID,
      name: "Local",
      url: sidecar.status.url ?? "",
      token: sidecar.status.token ?? "",
      mode: "local",
    };
  }

  /** All endpoints: local first, the built-in cloud nexus second, then any
   *  user-saved remotes (deduped against the built-in cloud id). */
  get endpoints(): NexusEndpoint[] {
    const saved = this.remotes.filter((e) => e.id !== CLOUD_ID);
    return [this.local, CLOUD_NEXUS, ...saved];
  }

  get active(): NexusEndpoint {
    return this.endpoints.find((e) => e.id === this.activeId) ?? this.local;
  }

  /** Live base URL for the active nexus — local reads discovery so it
   *  tracks the running runtime; remotes use their saved URL. */
  get activeUrl(): string | null {
    const a = this.active;
    return a.mode === "local" ? (sidecar.status.url ?? null) : a.url || null;
  }

  get activeToken(): string | null {
    const a = this.active;
    // OIDC nexuses carry no static token — the bearer comes from the WorkOS
    // keychain session via the OidcAdapter (see providers/tauri-local.ts).
    if (a.auth === "oidc") return null;
    return a.mode === "local" ? (sidecar.status.token ?? null) : a.token || null;
  }

  /** Auth rung of the active nexus — drives which adapter the RCP client uses. */
  get activeAuth(): NexusAuth {
    return this.active.auth ?? "token";
  }

  healthOf(id: string): NexusHealth {
    if (id === LOCAL_ID) {
      // Local health mirrors the sidecar probe.
      const s = sidecar.status.state;
      if (s === "ready") return "ok";
      if (s === "starting" || s === "restarting") return "checking";
      return "down";
    }
    return this.health[id] ?? "unknown";
  }

  #persist() {
    if (typeof localStorage === "undefined") return;
    try {
      localStorage.setItem(
        STORE_KEY,
        JSON.stringify({ remotes: this.remotes, activeId: this.activeId }),
      );
    } catch {
      /* storage full / disabled — selection is best-effort */
    }
  }

  select(id: string) {
    if (!this.endpoints.some((e) => e.id === id)) return;
    this.activeId = id;
    this.#persist();
  }

  /** Add a remote nexus from a URL + optional token. Returns its id. */
  add(input: { name: string; url: string; token?: string }): string {
    const url = input.url.trim().replace(/\/+$/, "");
    const id = `r_${url}_${this.remotes.length}`;
    const ep: NexusEndpoint = {
      id,
      name: input.name.trim() || url,
      url,
      token: (input.token ?? "").trim(),
      mode: "remote",
    };
    this.remotes = [...this.remotes, ep];
    this.#persist();
    void this.probe(id);
    return id;
  }

  remove(id: string) {
    if (id === LOCAL_ID || id === CLOUD_ID) return;
    this.remotes = this.remotes.filter((e) => e.id !== id);
    if (this.activeId === id) this.activeId = LOCAL_ID;
    const { [id]: _drop, ...rest } = this.health;
    this.health = rest;
    this.#persist();
  }

  /** Probe a remote nexus's /health. Local is covered by the sidecar. */
  async probe(id: string) {
    if (id === LOCAL_ID) return;
    const ep = this.endpoints.find((e) => e.id === id);
    if (!ep || !ep.url) return;
    this.health = { ...this.health, [id]: "checking" };
    try {
      const res = await fetch(`${ep.url}/health`, {
        headers: ep.token ? { authorization: `Bearer ${ep.token}` } : {},
        signal: AbortSignal.timeout(4000),
      });
      this.health = { ...this.health, [id]: res.ok ? "ok" : "down" };
    } catch {
      this.health = { ...this.health, [id]: "down" };
    }
  }

  probeAll() {
    for (const ep of this.endpoints) {
      if (ep.id !== LOCAL_ID) void this.probe(ep.id);
    }
  }
}

export const nexus = new NexusStore();
