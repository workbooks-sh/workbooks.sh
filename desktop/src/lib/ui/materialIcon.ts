/**
 * materialIcon — file/folder icons from the Material Icon Theme set
 * (material-icon-theme, MIT) — the standard look for anything that
 * represents a file or folder (wb-5fl.15).
 *
 * Precedence stays: an explicit emoji / image / identity icon on the
 * item wins; a user tint override wins for folders (tinted solid
 * glyph); the material icon is the default everything else falls to.
 */
import manifest from "material-icon-theme/dist/material-icons.json";

// Every icon svg as a hashed asset URL, resolved at build time.
const URLS = import.meta.glob(
  "/node_modules/material-icon-theme/icons/*.svg",
  { eager: true, query: "?url", import: "default" },
) as Record<string, string>;

function urlFor(def: string | undefined): string | null {
  if (!def) return null;
  return URLS[`/node_modules/material-icon-theme/icons/${def}.svg`] ?? null;
}

type Manifest = {
  folderNames: Record<string, string>;
  folderNamesExpanded: Record<string, string>;
  fileExtensions: Record<string, string>;
  fileNames: Record<string, string>;
  file: string;
  folder: string;
  folderExpanded: string;
};
const m = manifest as unknown as Manifest;

/** Direct lookup by material icon definition name (e.g. "rust",
 *  "folder-client"). Null when no such icon ships in the set. */
export function materialIconUrl(def: string): string | null {
  return urlFor(def);
}

/** Icon URL for a file, by its name (basename or full path). */
export function fileIconUrl(name: string): string {
  const base = name.split("/").pop()?.toLowerCase() ?? "";
  let def = m.fileNames[base];
  if (!def) {
    // Longest-suffix extension match — manifest keys include multi-dot
    // extensions like "d.ts", "test.tsx".
    const parts = base.split(".");
    for (let i = 1; i < parts.length && !def; i++) {
      def = m.fileExtensions[parts.slice(i).join(".")];
    }
  }
  return urlFor(def) ?? urlFor(m.file)!;
}

/** Icon URL for a folder, by name; `open` picks the expanded variant. */
export function folderIconUrl(name: string, open = false): string {
  const key = name.trim().toLowerCase();
  const def = open
    ? (m.folderNamesExpanded[key] ??
      // Fall back to the closed mapping's expanded twin when only the
      // closed name is mapped (manifest pairs are usually symmetric).
      (m.folderNames[key] ? `${m.folderNames[key]}-open` : undefined))
    : m.folderNames[key];
  return urlFor(def) ?? urlFor(open ? m.folderExpanded : m.folder)!;
}
