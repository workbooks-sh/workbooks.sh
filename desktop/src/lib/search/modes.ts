// Search-type metadata (wb-aakl.19). The three kinds are composites — naming
// them by data source ("web") is misleading (Ask also reaches the web), so
// they're named by the EXPERIENCE, and an explainer spells out what each does.

import type { SearchMode } from "./registry.svelte";

export interface SearchModeInfo {
  id: SearchMode;
  label: string;
  tagline: string;
  blurb: string;
}

export const SEARCH_MODES: Record<SearchMode, SearchModeInfo> = {
  internal: {
    id: "internal",
    label: "Workspace",
    tagline: "Local-first",
    blurb:
      "Fuzzy-searches your files and runtime, served straight from your nexus — fast and works offline. Stays on your own stuff; never hits the web.",
  },
  web: {
    id: "web",
    label: "Browse",
    tagline: "Your stuff + the open web",
    blurb:
      "Everything Workspace finds, plus live web results — click any of them to open the page right here in a tab.",
  },
  ai: {
    id: "ai",
    label: "Ask",
    tagline: "Answers, not just links",
    blurb:
      "Prompt it like a question. It reads your files and the web, then writes a short answer with the sources it used and a few follow-ups.",
  },
};

export const SEARCH_MODE_ORDER: SearchMode[] = ["internal", "web", "ai"];
