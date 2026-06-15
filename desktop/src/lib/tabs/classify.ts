// Path → TabKind classification. The host (src-tauri/src/tabs.rs) owns the
// authoritative classification in the packaged app; the webHost mock mirrors
// this for browser preview. Kept in one place so the two never drift.
//
// Wavelet compositions are HTML, so they need a marker that distinguishes
// them from rendered workbooks at classify-time (before content loads):
//   - extension `.wave.html` / `.comp.html`, OR
//   - any `.html` whose path sits under a directory named `compositions`
//     or `wavelet`.
// Everything else `.html?` is a workbook; `.org` is org; else text.

import type { TabKind } from "./types";

const WAVELET_EXT = /\.(?:wave|comp)\.html?$/i;
const WAVELET_DIR = /(?:^|\/)(?:compositions|wavelet)\//i;

export function classifyKind(path: string): TabKind {
  // An agent opens as a workbook tab of its own. The `agent://<slug>`
  // scheme (or any `.agent.org` file) routes to the in-tab AgentTabView
  // editor rather than the generic org/workbook viewers. The agent IS a
  // workbook — same tab surface, settings + human-in-the-loop + publish.
  if (/^agent:\/\//i.test(path) || /\.agent\.org$/i.test(path)) return "agent";
  if (WAVELET_EXT.test(path) || (WAVELET_DIR.test(path) && /\.html?$/i.test(path))) {
    return "wavelet";
  }
  if (/\.html?$/i.test(path)) return "workbook";
  if (/\.org$/i.test(path)) return "org";
  return "text";
}
