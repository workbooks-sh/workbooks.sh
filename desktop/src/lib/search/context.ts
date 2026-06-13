// Search SDK (wb-aakl.19) — the standard contract a search surface is built
// against, parallel to the sidebar SDK. The search host (SearchDrawer) owns
// the query/mode/results/AI state and exposes it here; any surface (the
// drawer today, a full-page or palette search tomorrow, a toolkit's own
// search UI) consumes the SAME api via useSearch().
//
// The three modes live on `mode`:
//   internal — fuzzy local/runtime results only (no web)
//   web      — web results (open pages) + internal
//   ai       — prompt → synthesised answer (answer, sources, follow-ups)
//
// Providers stay registered through the search registry (search.register),
// so toolkits contribute result sources the same way built-ins do; this SDK
// is the consumption side of that seam. Reactivity flows through getters.

import { getContext, setContext } from "svelte";
import type { SearchMode, ProviderResults } from "./registry.svelte";
import type { SearchResult } from "./types";
import type { AiAnswer } from "./aiPreview";

export interface SearchApi {
  readonly mode: SearchMode;
  setMode(m: SearchMode): void;

  readonly query: string;
  setQuery(q: string): void;

  readonly busy: boolean;
  /** Provider result groups, already filtered for the active mode. */
  readonly groups: ProviderResults[];
  /** Flat result list (group order) for keyboard navigation. */
  readonly flat: SearchResult[];
  readonly highlighted: number;
  setHighlighted(i: number): void;

  /** AI answer for the current prompt (ai mode), or null before submit. */
  readonly ai: AiAnswer | null;
  /** Run an AI answer for `q` (defaults to the current query). */
  ask(q?: string): void;

  /** Open a result / source (local path or web url) as a tab. */
  open(r: SearchResult): void;
  openTarget(t: { url?: string; path?: string }): void;

  /** Close the search surface. */
  close(): void;
}

const KEY = Symbol("wb.search");

export function setSearch(api: SearchApi): void {
  setContext(KEY, api);
}
export function useSearch(): SearchApi {
  const api = getContext<SearchApi | undefined>(KEY);
  if (!api) throw new Error("useSearch() called outside a search host");
  return api;
}

export type { SearchMode, ProviderResults, SearchResult, AiAnswer };
