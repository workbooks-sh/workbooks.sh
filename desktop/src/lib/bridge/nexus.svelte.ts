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

export interface NexusEndpoint {
  id: string;
  name: string;
  /** Resolved base URL, e.g. https://nexus.example.com:4000. Empty for
   *  the local entry (it reads the live discovery URL instead). */
  url: string;
  /** Per-nexus bearer. Empty for local (reads the discovery token). */
  token: string;
  mode: NexusMode;
}

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

  /** All endpoints, local first. */
  get endpoints(): NexusEndpoint[] {
    return [this.local, ...this.remotes];
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
    return a.mode === "local" ? (sidecar.status.token ?? null) : a.token || null;
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
    if (id === LOCAL_ID) return;
    this.remotes = this.remotes.filter((e) => e.id !== id);
    if (this.activeId === id) this.activeId = LOCAL_ID;
    const { [id]: _drop, ...rest } = this.health;
    this.health = rest;
    this.#persist();
  }

  /** Probe a remote nexus's /health. Local is covered by the sidecar. */
  async probe(id: string) {
    const ep = this.remotes.find((e) => e.id === id);
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
    for (const ep of this.remotes) void this.probe(ep.id);
  }
}

export const nexus = new NexusStore();
