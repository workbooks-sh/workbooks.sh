// Demo content for the onboarding tour (wb-aakl.20). One source of truth so
// the sidebar rail, the workspace dropdown, the package list, and folder
// expansion all show the SAME data. The tour runs before any runtime or real
// workspaces exist, so without this everything reads blank.
//
// Folder children use real file paths with extensions → the Material Icon
// Theme resolves the same icons the live app uses (so the demo matches).

import type { WorkbookEntry } from "$lib/bridge/package.svelte";

// Each demo item carries BOTH glyph forms so the "emoji vs icon" onboarding
// step can flip the whole sidebar live. `icon` is the emoji; `mi` is the
// Material-icon ref used in icon mode.
export interface DemoWorkspace {
  id: string;
  name: string;
  icon: string; // emoji
  mi: string; // material-icon ref
}

export const DEMO_WORKSPACES: DemoWorkspace[] = [
  { id: "personal", name: "Personal", icon: "🏠", mi: "mi:todo" },
  { id: "acme", name: "Acme", icon: "🅰", mi: "mi:rocket" },
  { id: "studio", name: "Studio", icon: "🎨", mi: "mi:image" },
  { id: "research", name: "Research", icon: "🔬", mi: "mi:database" },
];

export const DEMO_ACTIVE_WORKSPACE = DEMO_WORKSPACES[0];

export interface DemoPackage {
  id: string;
  name: string;
  kind: "folder" | "app";
  emoji: string; // folder badge in emoji mode
  badge: string; // folder badge (material-icon ref) in icon mode
}

// All folders — the tinted FolderIcon is the picked identity; twirl them open
// to reveal files whose icons come from the Material Icon Theme by extension
// (icon mode) or an emoji (emoji mode). Each folder carries both badge forms.
export const DEMO_PACKAGES: DemoPackage[] = [
  { id: "Reading", name: "Reading", kind: "folder", emoji: "📚", badge: "mi:lib" },
  { id: "Design", name: "Design", kind: "folder", emoji: "🎨", badge: "mi:image" },
  { id: "Clients", name: "Clients", kind: "folder", emoji: "🤝", badge: "mi:todo" },
  { id: "Finance", name: "Finance", kind: "folder", emoji: "💰", badge: "mi:table" },
  { id: "Research", name: "Research", kind: "folder", emoji: "🔬", badge: "mi:database" },
  { id: "Brand", name: "Brand", kind: "folder", emoji: "✨", badge: "mi:svg" },
  { id: "Roadmap", name: "Roadmap", kind: "folder", emoji: "🗺️", badge: "mi:rocket" },
  { id: "Notes", name: "Notes", kind: "folder", emoji: "📝", badge: "mi:document" },
];

// Emoji for a file path (emoji mode) — by extension, mirroring how the icon
// mode resolves a Material icon from the same extension.
const EXT_EMOJI: Record<string, string> = {
  md: "📝", org: "📑", canvas: "🖼️", svg: "🖼️", json: "⚙️", py: "🐍",
  ipynb: "📓", css: "🎨", xlsx: "📊", csv: "📈", html: "🌐", txt: "📄",
};
export function emojiForPath(path: string): string {
  const ext = path.split(".").pop()?.toLowerCase() ?? "";
  return EXT_EMOJI[ext] ?? "📄";
}

export const DEMO_FOLDER_CHILDREN: Record<string, WorkbookEntry[]> = {
  Reading: [
    { path: "Reading/Designing Data-Intensive Apps.md", title: "Designing Data-Intensive Apps" },
    { path: "Reading/The Pragmatic Programmer.md", title: "The Pragmatic Programmer" },
    { path: "Reading/Reading List.org", title: "Reading List" },
  ],
  Design: [
    { path: "Design/Brand System.canvas", title: "Brand System" },
    { path: "Design/Logo Explorations.svg", title: "Logo Explorations" },
    { path: "Design/Tokens.json", title: "Tokens" },
  ],
  Clients: [
    { path: "Clients/Acme Proposal.md", title: "Acme Proposal" },
    { path: "Clients/Onboarding.org", title: "Onboarding" },
  ],
  Finance: [
    { path: "Finance/Q3 Forecast.xlsx", title: "Q3 Forecast" },
    { path: "Finance/Invoices.csv", title: "Invoices" },
  ],
  Research: [
    { path: "Research/Notebook.ipynb", title: "Notebook" },
    { path: "Research/analysis.py", title: "analysis.py" },
    { path: "Research/Findings.md", title: "Findings" },
  ],
  Brand: [
    { path: "Brand/Voice & Tone.md", title: "Voice & Tone" },
    { path: "Brand/Palette.css", title: "Palette" },
  ],
  Roadmap: [
    { path: "Roadmap/2026 Plan.org", title: "2026 Plan" },
    { path: "Roadmap/Milestones.md", title: "Milestones" },
  ],
  Notes: [
    { path: "Notes/Daily.md", title: "Daily" },
    { path: "Notes/Ideas.md", title: "Ideas" },
    { path: "Notes/Meeting — Standup.md", title: "Meeting — Standup" },
  ],
};
