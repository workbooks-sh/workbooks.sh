// Composable search registry (wb-aakl.19).
//
// Holds the registered providers + per-provider enable/order (persisted),
// and runs every enabled provider for a query. SDK-shaped: a toolkit
// registers a provider exactly like a built-in (wb-aakl.15 / wb-aakl.5's
// "add a provider" onboarding step). The UI groups results by provider.

import type { SearchProvider, SearchResult } from "./types";

const PREFS_KEY = "wb.search.prefs.v1";
const MODE_KEY = "wb.search.mode";

// The three search kinds:
//   internal — fuzzy local/runtime results only (no web)
//   web      — web results (open pages) + internal
//   ai       — prompt → synthesized answer page (answer, sources, follow-ups)
export type SearchMode = "internal" | "web" | "ai";

function loadMode(): SearchMode {
  // Default to local-first Workspace search — never the web. Web search is a
  // paid/token surface and is opt-in (the `web` provider is off by default; the
  // user enables it in Settings). See loadPrefs.
  if (typeof localStorage === "undefined") return "internal";
  const m = localStorage.getItem(MODE_KEY);
  return m === "internal" || m === "web" || m === "ai" ? m : "internal";
}

// The web-search backends the nexus can route to (matches the runtime's
// Browse.Search provider seam). "openrouter" is the reliable default (reuses the
// model key); "keyless" is the no-key best-effort scrape; the rest need a key
// configured in the runtime. The picker writes `webProvider`; the web provider
// sends it to /api/browse/search?provider=…
export const WEB_PROVIDERS = ["openrouter", "keyless", "exa", "brave_api", "perplexity"] as const;
export type WebProvider = (typeof WEB_PROVIDERS)[number];

// Friendly labels for the provider picker (shared by the onboarding explainer +
// the search drawer's web lane, so they never drift).
export const WEB_PROVIDER_LABELS: Record<WebProvider, string> = {
  openrouter: "OpenRouter — reliable",
  keyless: "Keyless — no setup",
  exa: "Exa (needs key)",
  brave_api: "Brave API (needs key)",
  perplexity: "Perplexity (needs key)",
};

interface Prefs {
  disabled: string[]; // provider ids the user turned off
  order: string[]; // provider id order (registered ids not listed sort last)
  webProvider: WebProvider; // which backend the opt-in "web" lane uses
}

function loadPrefs(): Prefs {
  // Web search is OPT-IN: the `web` provider (a paid/token surface) starts
  // disabled so the default search never hits the web. The user enables it in
  // Settings (and configures the provider/key in the runtime).
  const DEFAULT: Prefs = { disabled: ["web"], order: [], webProvider: "openrouter" };
  if (typeof localStorage === "undefined") return DEFAULT;
  try {
    const raw = localStorage.getItem(PREFS_KEY);
    if (!raw) return DEFAULT;
    const p = JSON.parse(raw);
    return {
      disabled: Array.isArray(p.disabled) ? p.disabled : ["web"],
      order: Array.isArray(p.order) ? p.order : [],
      webProvider: WEB_PROVIDERS.includes(p.webProvider) ? p.webProvider : "openrouter",
    };
  } catch {
    return DEFAULT;
  }
}

export interface ProviderResults {
  provider: SearchProvider;
  results: SearchResult[];
  error?: string;
}

class SearchRegistry {
  providers = $state<SearchProvider[]>([]);
  #prefs = $state<Prefs>(loadPrefs());

  /** Active search kind (internal / web / ai). */
  mode = $state<SearchMode>(loadMode());
  /** A query the drawer seeds itself with when opened for a preview. */
  demoQuery = $state<string>("");
  setMode(m: SearchMode): void {
    this.mode = m;
    try { localStorage.setItem(MODE_KEY, m); } catch { /* non-fatal */ }
  }

  /** The backend the opt-in web lane queries (set by the Settings picker). */
  get webProvider(): WebProvider {
    return this.#prefs.webProvider;
  }
  setWebProvider(p: WebProvider): void {
    this.#prefs = { ...this.#prefs, webProvider: p };
    this.#persist();
  }

  register(p: SearchProvider): void {
    if (this.providers.some((x) => x.id === p.id)) return;
    this.providers = [...this.providers, p];
  }
  unregister(id: string): void {
    this.providers = this.providers.filter((p) => p.id !== id);
  }

  isEnabled(id: string): boolean {
    return !this.#prefs.disabled.includes(id);
  }
  setEnabled(id: string, on: boolean): void {
    const disabled = new Set(this.#prefs.disabled);
    if (on) disabled.delete(id);
    else disabled.add(id);
    this.#prefs = { ...this.#prefs, disabled: [...disabled] };
    this.#persist();
  }

  /** Enabled providers, in the user's order (unordered ids keep registration order). */
  get active(): SearchProvider[] {
    const order = this.#prefs.order;
    return this.providers
      .filter((p) => this.isEnabled(p.id))
      .slice()
      .sort((a, b) => {
        const ia = order.indexOf(a.id);
        const ib = order.indexOf(b.id);
        if (ia === -1 && ib === -1) return 0;
        if (ia === -1) return 1;
        if (ib === -1) return -1;
        return ia - ib;
      });
  }

  /** Run every active provider concurrently; return per-provider result
   *  groups (in active order). A provider that throws yields an error
   *  group rather than failing the whole search. */
  async searchAll(query: string): Promise<ProviderResults[]> {
    const provs = this.active;
    const settled = await Promise.all(
      provs.map(async (p): Promise<ProviderResults> => {
        try {
          const results = await p.search(query);
          const sorted = results
            .slice()
            .sort((a, b) => (b.score ?? 0) - (a.score ?? 0));
          return { provider: p, results: sorted };
        } catch (e) {
          return { provider: p, results: [], error: e instanceof Error ? e.message : String(e) };
        }
      }),
    );
    return settled;
  }

  #persist(): void {
    if (typeof localStorage === "undefined") return;
    try {
      localStorage.setItem(PREFS_KEY, JSON.stringify(this.#prefs));
    } catch {
      /* best-effort */
    }
  }
}

export const search = new SearchRegistry();
