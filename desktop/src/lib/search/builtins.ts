// Built-in search providers (wb-aakl.19): local files/workbooks, bookmarks,
// open tabs, and the nexus web lane. Registered at app start; each is a peer
// of any toolkit-registered provider.

import { File as FileIcon, BookmarkSimple, Browsers, Globe } from "phosphor-svelte";
import { bookmarks } from "$lib/bridge/bookmarks.svelte";
import { tabs } from "$lib/tabs/store.svelte";
import { nexus } from "$lib/bridge/nexus.svelte";
import { fileIndex, fileCrumb } from "./fileIndex.svelte";
import type { SearchProvider, SearchResult } from "./types";

const WORKBOOK_EXT = /\.(html?|org)$/i;

function fuzzyScore(q: string, name: string, rel: string): number | null {
  const n = name.toLowerCase();
  const r = rel.toLowerCase();
  let score: number;
  if (n === q) score = 1000;
  else if (n.startsWith(q)) score = 800;
  else if (n.includes(q)) score = 600;
  else if (r.includes(q)) score = 400;
  else return null;
  return score - rel.length;
}

/** Files + workbooks across the active workspace. Workbooks (.html/.org)
 *  are tagged as their own kind so the UI can lead with them. */
export const filesProvider: SearchProvider = {
  id: "files",
  label: "Files",
  icon: FileIcon,
  kinds: ["file", "workbook"],
  search(query: string): SearchResult[] {
    fileIndex.ensure();
    const q = query.trim().toLowerCase();
    const hits = fileIndex.entries;
    const ranked = (q
      ? hits
          .map((h) => {
            const s = fuzzyScore(q, h.entry.name, h.entry.rel);
            return s === null ? null : { h, s };
          })
          .filter((x): x is { h: (typeof hits)[number]; s: number } => !!x)
      : hits.slice(0, 100).map((h) => ({ h, s: 0 }))
    ).slice(0, 100);
    return ranked.map(({ h, s }) => ({
      kind: WORKBOOK_EXT.test(h.entry.name) ? "workbook" : "file",
      title: h.entry.name,
      subtitle: fileCrumb(h),
      path: h.entry.path,
      providerId: "files",
      score: s,
    }));
  },
};

export const bookmarksProvider: SearchProvider = {
  id: "bookmarks",
  label: "Bookmarks",
  icon: BookmarkSimple,
  kinds: ["bookmark"],
  search(query: string): SearchResult[] {
    const q = query.trim().toLowerCase();
    return bookmarks.bookmarks
      .filter((b) => !q || b.title.toLowerCase().includes(q) || b.path.toLowerCase().includes(q))
      .slice(0, 50)
      .map((b) => ({
        kind: "bookmark",
        title: b.title,
        subtitle: b.path,
        path: b.path,
        providerId: "bookmarks",
        score: q && b.title.toLowerCase().startsWith(q) ? 100 : 0,
      }));
  },
};

export const tabsProvider: SearchProvider = {
  id: "tabs",
  label: "Open tabs",
  icon: Browsers,
  kinds: ["tab"],
  search(query: string): SearchResult[] {
    const q = query.trim().toLowerCase();
    return tabs.tabs
      .filter((t) => !q || t.title.toLowerCase().includes(q) || t.path.toLowerCase().includes(q))
      .map((t) => ({
        kind: "tab",
        title: t.title,
        subtitle: t.path,
        path: t.path,
        providerId: "tabs",
        score: 0,
      }));
  },
};

/** Web search via the connected nexus (the Elixir Browse.Search lane).
 *  Zero keys when the nexus carries DataForSEO; empty + silent when no
 *  nexus / route. Results open in a tab through the readability path. */
export const nexusWebProvider: SearchProvider = {
  id: "web",
  label: "Web",
  icon: Globe,
  kinds: ["web"],
  async search(query: string): Promise<SearchResult[]> {
    const q = query.trim();
    if (!q) return [];
    const base = nexus.activeUrl;
    if (!base) return [];
    const token = nexus.activeToken;
    try {
      const res = await fetch(`${base}/api/browse/search?q=${encodeURIComponent(q)}`, {
        headers: token ? { authorization: `Bearer ${token}` } : {},
        signal: AbortSignal.timeout(8000),
      });
      if (!res.ok) return [];
      const data = (await res.json()) as { results?: { title: string; url: string; snippet?: string }[] };
      return (data.results ?? []).map((r, i) => ({
        kind: "web",
        title: r.title || r.url,
        subtitle: r.snippet || r.url,
        url: r.url,
        providerId: "web",
        score: 100 - i, // preserve SERP order
      }));
    } catch {
      return [];
    }
  },
};

export const BUILTIN_PROVIDERS: SearchProvider[] = [
  filesProvider,
  bookmarksProvider,
  tabsProvider,
  nexusWebProvider,
];
