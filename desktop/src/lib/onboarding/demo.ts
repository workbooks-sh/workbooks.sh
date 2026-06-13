// Demo content for the onboarding tour (wb-aakl.20). One source of truth so
// the sidebar rail, the workspace dropdown, the package list, and folder
// expansion all show the SAME data. The tour runs before any runtime or real
// workspaces exist, so without this everything reads blank.
//
// Folder children use real file paths with extensions → the Material Icon
// Theme resolves the same icons the live app uses (so the demo matches).

import type { WorkbookEntry } from "$lib/bridge/package.svelte";

export interface DemoWorkspace {
  id: string;
  name: string;
  icon: string;
}

export const DEMO_WORKSPACES: DemoWorkspace[] = [
  { id: "personal", name: "Personal", icon: "🏠" },
  { id: "acme", name: "Acme", icon: "🅰" },
  { id: "studio", name: "Studio", icon: "🎨" },
  { id: "research", name: "Research", icon: "🔬" },
];

export const DEMO_ACTIVE_WORKSPACE = DEMO_WORKSPACES[0];

export interface DemoPackage {
  id: string;
  name: string;
  kind: "folder" | "app";
}

// All folders — the tinted FolderIcon is the picked identity; twirl them open
// to reveal files whose icons come from the Material Icon Theme by extension.
export const DEMO_PACKAGES: DemoPackage[] = [
  { id: "Reading", name: "Reading", kind: "folder" },
  { id: "Design", name: "Design", kind: "folder" },
  { id: "Clients", name: "Clients", kind: "folder" },
  { id: "Finance", name: "Finance", kind: "folder" },
  { id: "Research", name: "Research", kind: "folder" },
  { id: "Brand", name: "Brand", kind: "folder" },
  { id: "Roadmap", name: "Roadmap", kind: "folder" },
  { id: "Notes", name: "Notes", kind: "folder" },
];

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
