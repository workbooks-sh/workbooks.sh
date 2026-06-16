// pm-shared — the small DRY layer for the PM + flow structural elements.
// Status tones, priority enum, the meta-row CSS, and the field/initials helpers
// are authored ONCE here and reused by board-task / board-view / board-sprint /
// board-milestone / work-flow / work-loop. Every component renders its own
// attributes (no post-hoc regex chrome); these just keep that rendering uniform
// and token-only (var(--work-*) exclusively).
import { html, css } from "../../core/element.js";

// status → { label, tone } where tone selects the pill color via [data-tone].
// One canonical status vocabulary across PM + flow (the org TODO/DONE state,
// re-expressed as a plain attribute; see docs/WORK-FORMAT.md).
export const STATUS = {
  todo:    { label: "To do",   tone: "neutral" },
  doing:   { label: "Doing",   tone: "brand" },
  review:  { label: "Review",  tone: "warn" },
  done:    { label: "Done",    tone: "ok" },
  blocked: { label: "Blocked", tone: "err" },
  // flow/loop runtime states share the same pill machinery
  idle:    { label: "Idle",    tone: "neutral" },
  running: { label: "Running", tone: "brand" },
  paused:  { label: "Paused",  tone: "warn" },
  failed:  { label: "Failed",  tone: "err" },
  ok:      { label: "OK",      tone: "ok" },
};

export const STATUS_ORDER = ["todo", "doing", "review", "done", "blocked"];
export const PRIORITY = ["low", "med", "high", "urgent"];

/** Two-letter initials for an avatar chip from an assignee/owner string. */
export function initials(name) {
  return String(name || "")
    .replace(/^@/, "")
    .split(/[\s._-]+/)
    .filter(Boolean)
    .map((w) => w[0])
    .join("")
    .slice(0, 2)
    .toUpperCase() || "?";
}

/** A labeled inline meta field; renders nothing when the value is empty. */
export function fieldRow(label, value) {
  return value ? html`<span class="field"><span class="flabel">${label}</span>${value}</span>` : "";
}

/** The status pill markup, given a status key (falls back to neutral/unknown). */
export function pill(status) {
  const s = STATUS[status] || { label: status || "—", tone: "neutral" };
  return html`<span class="pill" data-tone=${s.tone}>${s.label}</span>`;
}

// Shared meta-row + pill CSS — spliced into each element's `static styles` so the
// status pills, avatars and field chips look identical everywhere. Token-only.
export const metaCss = css`
  .meta { display: flex; flex-wrap: wrap; align-items: center; gap: var(--work-space-2) var(--work-space-3); font-size: var(--work-text-sm); color: var(--work-fg-muted); }
  .field { display: inline-flex; align-items: center; gap: var(--work-space-1); }
  .flabel { font-family: var(--work-font-mono); font-size: var(--work-text-2xs); text-transform: uppercase; letter-spacing: .05em; color: var(--work-fg-subtle); }
  .who { display: inline-flex; align-items: center; gap: var(--work-space-1); }
  .avatar { display: inline-grid; place-items: center; width: 20px; height: 20px; border-radius: var(--work-radius-pill);
    background: var(--work-brand-soft); color: var(--work-fg); font-size: var(--work-text-2xs); font-weight: 700; border: 1px solid var(--work-border); }

  .pill { display: inline-flex; align-items: center; padding: 1px var(--work-space-2); border-radius: var(--work-radius-pill);
    font-size: var(--work-text-2xs); font-weight: 600; line-height: 1.5; white-space: nowrap;
    border: 1px solid var(--work-border); background: var(--work-surface-soft); color: var(--work-fg-muted); }
  .pill[data-tone="brand"] { border-color: color-mix(in srgb, var(--work-brand) 45%, transparent); background: var(--work-brand-soft); color: var(--work-brand-ink); }
  .pill[data-tone="ok"]    { border-color: color-mix(in srgb, var(--work-ok) 45%, transparent);   background: var(--work-ok-soft);   color: var(--work-ok); }
  .pill[data-tone="warn"]  { border-color: color-mix(in srgb, var(--work-warn) 45%, transparent); background: var(--work-warn-soft); color: var(--work-warn); }
  .pill[data-tone="err"]   { border-color: color-mix(in srgb, var(--work-err) 45%, transparent);  background: var(--work-err-soft);  color: var(--work-err); }
`;
