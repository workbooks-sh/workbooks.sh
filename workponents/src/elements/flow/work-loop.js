// <work-loop> — a recurring job: a named task on a cron cadence with a run status.
// Renders its own attributes as a compact card — the cron expression (with a plain
// human gloss for the common cadences), the current status pill, and its prose body
// (what the loop does). The org recurrence idea, re-expressed as a `cron=` attribute.
//
// Time is host-injected: the loop displays its `cron` cadence and does pure
// presentation. It does NOT compute or read "next fire" from a clock — the kernel
// computes fire-times relative to an injected `now` and the host's scheduler fires
// them. The loop never sleeps, reads the clock, or triggers (docs/WORK-FORMAT.md).
//
// Attributes:
//   title    the loop name
//   cron     a 5-field cron expression ("0 9 * * 1")
//   status   idle | running | paused | failed | ok   (reflected → status pill)
import { WbElement, html, css, define } from "../../core/element.js";
import { pill, metaCss } from "../pm/pm-shared.js";

// A best-effort plain gloss for the common cron cadences (pure string mapping —
// no date math, no clock). Falls back to the raw expression.
function cronGloss(expr) {
  const known = {
    "* * * * *": "every minute",
    "0 * * * *": "hourly",
    "0 0 * * *": "daily at midnight",
    "0 9 * * *": "daily at 09:00",
    "0 9 * * 1": "every Monday at 09:00",
    "0 0 * * 0": "weekly on Sunday",
    "0 0 1 * *": "monthly on the 1st",
  };
  return known[String(expr || "").trim()] || null;
}

export class WorkLoop extends WbElement {
  static props = ["title", "cron", "status"];

  static styles = css`
    :host { display: block; font-family: var(--work-font); color: var(--work-fg); font-size: var(--work-text); }
    .card { display: flex; flex-direction: column; gap: var(--work-space-2);
      padding: var(--work-space-3) var(--work-space-4); border: 1px solid var(--work-border);
      border-radius: var(--work-radius); background: var(--work-surface); }
    :host([status="failed"]) .card { border-color: color-mix(in srgb, var(--work-err) 45%, var(--work-border)); }
    .head { display: flex; align-items: center; gap: var(--work-space-2); }
    .glyph { width: 15px; height: 15px; flex: none; color: var(--work-fg-muted); }
    :host([status="running"]) .glyph { color: var(--work-brand); animation: spin 2.4s linear infinite; }
    @keyframes spin { to { transform: rotate(360deg); } }
    .title { font-weight: 600; flex: 1 1 auto; }
    .body { color: var(--work-fg-muted); line-height: 1.5; white-space: pre-wrap; word-break: break-word; }
    .cron { font-family: var(--work-font-mono); font-size: var(--work-text-sm);
      background: var(--work-surface-soft); border: 1px solid var(--work-border);
      border-radius: var(--work-radius-sm); padding: 1px var(--work-space-2); color: var(--work-fg-muted); }
    .gloss { font-size: var(--work-text-sm); color: var(--work-fg-subtle); }
    ${metaCss}
  `;

  get body() { return (this.textContent || "").trim(); }

  render() {
    const title = this.attr("title", "Loop");
    const cron = this.attr("cron");
    const status = this.attr("status", "idle");
    const gloss = cronGloss(cron);
    return html`
      <div class="card">
        <div class="head">
          <svg class="glyph" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
            <path d="M21 12a9 9 0 11-3-6.7M21 3v5h-5"></path>
          </svg>
          <span class="title">${title}</span>
          ${pill(status)}
        </div>
        ${this.body ? html`<div class="body">${this.body}</div>` : ""}
        <div class="meta">
          ${cron ? html`<span class="cron">${cron}</span>` : ""}
          ${gloss ? html`<span class="gloss">${gloss}</span>` : ""}
        </div>
      </div>`;
  }
}

define("work-loop", WorkLoop);
