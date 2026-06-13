// Composable search registry (wb-aakl.19).
//
// Holds the registered providers + per-provider enable/order (persisted),
// and runs every enabled provider for a query. SDK-shaped: a toolkit
// registers a provider exactly like a built-in (wb-aakl.15 / wb-aakl.5's
// "add a provider" onboarding step). The UI groups results by provider.

import type { SearchProvider, SearchResult } from "./types";

const PREFS_KEY = "wb.search.prefs.v1";

interface Prefs {
  disabled: string[]; // provider ids the user turned off
  order: string[]; // provider id order (registered ids not listed sort last)
}

function loadPrefs(): Prefs {
  if (typeof localStorage === "undefined") return { disabled: [], order: [] };
  try {
    const raw = localStorage.getItem(PREFS_KEY);
    if (!raw) return { disabled: [], order: [] };
    const p = JSON.parse(raw);
    return {
      disabled: Array.isArray(p.disabled) ? p.disabled : [],
      order: Array.isArray(p.order) ? p.order : [],
    };
  } catch {
    return { disabled: [], order: [] };
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
