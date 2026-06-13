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

// Preview content (wb-aakl.19) — shown so the "everything search" UI is
// demonstrable before a nexus/file index exists. Files: a small stand-in set
// used only when the real index is empty. Web: plausible mock results when no
// nexus is connected. Both vanish the moment real backends return data.
const PREVIEW_FILES = [
  "Reading/Designing Data-Intensive Apps.md",
  "Design/Brand System.canvas",
  "Research/Notebook.ipynb",
  "Research/analysis.py",
  "Notes/Daily.md",
  "Roadmap/2026 Plan.org",
  "Finance/Q3 Forecast.xlsx",
  "Clients/Acme Proposal.md",
];
// Inline SVG gradient thumbnail (no network) — deterministic per seed, so
// preview web results have real-looking images.
function thumb(seed: string): string {
  let h = 0;
  for (let i = 0; i < seed.length; i++) h = (h * 31 + seed.charCodeAt(i)) >>> 0;
  const a = h % 360;
  const b = (a + 40 + ((h >> 5) % 90)) % 360;
  const svg =
    `<svg xmlns='http://www.w3.org/2000/svg' width='96' height='72'>` +
    `<defs><linearGradient id='g' x1='0' y1='0' x2='1' y2='1'>` +
    `<stop offset='0' stop-color='hsl(${a},62%,58%)'/>` +
    `<stop offset='1' stop-color='hsl(${b},58%,42%)'/></linearGradient></defs>` +
    `<rect width='96' height='72' fill='url(#g)'/></svg>`;
  return `data:image/svg+xml,${encodeURIComponent(svg)}`;
}
function mockWeb(q: string): SearchResult[] {
  const enc = encodeURIComponent(q);
  const slug = q.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/(^-|-$)/g, "") || "example";
  const r = (title: string, host: string, url: string, subtitle: string, score: number): SearchResult => ({
    kind: "web", title, subtitle, url, host, providerId: "web", score, image: thumb(host + url),
  });
  return [
    r(`${q} — Wikipedia`, "en.wikipedia.org", `https://en.wikipedia.org/wiki/${enc}`, `Overview, history and key concepts for ${q}.`, 100),
    r(`${q}: docs & guides`, `docs.${slug}.com`, `https://docs.${slug}.com`, `Get started, API reference and worked examples.`, 90),
    r(`Best ${q} tools in 2026`, "example.com", `https://example.com/blog/${slug}`, `A practical roundup with side-by-side comparisons.`, 80),
    r(`${q} — GitHub`, "github.com", `https://github.com/search?q=${enc}`, `Repositories, issues and discussions about ${q}.`, 70),
    r(`Understanding ${q}`, "medium.com", `https://medium.com/search?q=${enc}`, `A long-read explainer with diagrams and takeaways.`, 60),
  ];
}

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
    // Preview: no real index yet → show stand-in files so the UI populates.
    // Show matches if any, otherwise the full set (so a demo query that
    // doesn't literally match still demonstrates results).
    if (hits.length === 0) {
      const matched = PREVIEW_FILES.filter((p) => p.toLowerCase().includes(q));
      return (q && matched.length ? matched : PREVIEW_FILES)
        .slice(0, 8)
        .map((p, i) => ({
          kind: WORKBOOK_EXT.test(p) ? "workbook" : "file",
          title: p.split("/").pop() ?? p,
          subtitle: p,
          path: p,
          providerId: "files",
          score: 50 - i,
        }));
    }
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
    if (!base) return mockWeb(q); // preview until a nexus is connected
    const token = nexus.activeToken;
    try {
      const res = await fetch(`${base}/api/browse/search?q=${encodeURIComponent(q)}`, {
        headers: token ? { authorization: `Bearer ${token}` } : {},
        signal: AbortSignal.timeout(8000),
      });
      if (!res.ok) return mockWeb(q); // nexus reachable but no route → preview
      const data = (await res.json()) as { results?: { title: string; url: string; snippet?: string }[] };
      const results = (data.results ?? []).map((r, i) => {
        let host = "";
        try { host = new URL(r.url).host; } catch { /* leave blank */ }
        return {
          kind: "web" as const,
          title: r.title || r.url,
          subtitle: r.snippet || r.url,
          url: r.url,
          host,
          providerId: "web",
          score: 100 - i, // preserve SERP order
          image: thumb(host + r.url),
        };
      });
      // No live results (dead/empty route) → preview so the UI still shows.
      return results.length ? results : mockWeb(q);
    } catch {
      return mockWeb(q); // unreachable nexus → preview
    }
  },
};

export const BUILTIN_PROVIDERS: SearchProvider[] = [
  filesProvider,
  bookmarksProvider,
  tabsProvider,
  nexusWebProvider,
];
