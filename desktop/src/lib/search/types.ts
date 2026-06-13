// Composable search (wb-aakl.19) — provider contract.
//
// Search is an extensible surface, not a fixed feature: each SearchProvider
// contributes results of one or more kinds, the registry runs every enabled
// provider and the UI groups them. Built-ins cover files/workbooks/
// bookmarks/tabs + the nexus web lane; third-party providers (Exa, Tavily,
// an AI answerer) arrive as toolkits via the Browser SDK. The contract is
// SDK-shaped from day one so a toolkit-registered provider is a peer of the
// built-ins.

import type { Component } from "svelte";

export type SearchKind =
  | "file"
  | "workbook"
  | "bookmark"
  | "tab"
  | "web"
  | "answer";

export interface SearchResult {
  kind: SearchKind;
  title: string;
  /** Secondary line — path crumb, url host, snippet. */
  subtitle?: string;
  /** A local open target (file/workbook path)… */
  path?: string;
  /** …or a web target (opened in a tab via the readability path). */
  url?: string;
  providerId: string;
  /** Higher sorts first within a provider group. */
  score?: number;
  /** Optional thumbnail (data-URI or url) — web results render richer cards. */
  image?: string;
  /** Optional source host for web results (e.g. "en.wikipedia.org"). */
  host?: string;
}

export interface SearchProvider {
  id: string;
  label: string;
  icon?: Component<any> | null;
  kinds: SearchKind[];
  /** Run the query. Sync (local) or async (nexus/web/AI). Should return
   *  quickly or resolve; the registry races them and renders as they land.
   *  An empty query may return a default set (recent/all) or []. */
  search(query: string): SearchResult[] | Promise<SearchResult[]>;
}
