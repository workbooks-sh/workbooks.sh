// <work-task> — the PM leaf: a single unit of work as a themed card that renders
// its own org-derived attributes (status pill, assignee, due, estimate, priority)
// and its prose body. The HTML element IS the source — no JSON IR, no regex chrome
// injected after the fact (the old org `:PROPERTIES:` drawer collapses into plain
// attributes here; see docs/WORK-FORMAT.md).
//
// Time is host-injected: this element does pure presentation of the value strings
// it is given (ISO instants, `3d`/`P3D` durations). It never reads a system clock —
// "now" is a parameter the host supplies elsewhere. So `due` is displayed as-authored.
//
// Attributes:
//   status     todo | doing | done | blocked | review   (reflected → status pill)
//   title      the task title (also the default-slot fallback)
//   assignee   who owns it (@name sugar maps here)        → avatar chip
//   due        ISO-8601 instant the work is due
//   estimate   duration shorthand (3d / 2h30m / P3D)
//   priority   low | med | high | urgent                 (reflected → priority dot)
//
// The body (light-DOM text/markup) renders as the task detail.
import { WbElement, html, css, define } from "../../core/element.js";
import { STATUS, PRIORITY, initials, fieldRow, metaCss } from "./pm-shared.js";

export class WorkTask extends WbElement {
  static props = ["status", "title", "assignee", "due", "estimate", "priority"];

  static styles = css`
    :host {
      display: block;
      font-family: var(--work-font);
      color: var(--work-fg);
      font-size: var(--work-text);
    }
    .card {
      display: flex;
      flex-direction: column;
      gap: var(--work-space-2);
      padding: var(--work-space-3) var(--work-space-4);
      border: 1px solid var(--work-border);
      border-radius: var(--work-radius);
      background: var(--work-surface);
    }
    :host([priority="urgent"]) .card,
    :host([priority="high"]) .card { border-left: 3px solid var(--work-warn); }
    :host([status="done"]) .title { text-decoration: line-through; color: var(--work-fg-muted); }
    :host([status="blocked"]) .card { border-color: color-mix(in srgb, var(--work-err) 45%, var(--work-border)); }

    .head { display: flex; align-items: center; gap: var(--work-space-2); }
    .title { font-weight: 600; line-height: 1.3; flex: 1 1 auto; }
    .body { color: var(--work-fg-muted); line-height: 1.5; white-space: pre-wrap; word-break: break-word; }
    ${metaCss}
    .prio { width: 8px; height: 8px; border-radius: var(--work-radius-pill); flex: none; background: var(--work-fg-subtle); }
    .prio[data-p="med"] { background: var(--work-brand); }
    .prio[data-p="high"] { background: var(--work-warn); }
    .prio[data-p="urgent"] { background: var(--work-err); }
  `;

  get body() { return (this.textContent || "").trim(); }

  render() {
    const status = this.attr("status", "todo");
    const title = this.attr("title", this.body);
    const assignee = this.attr("assignee");
    const due = this.attr("due");
    const estimate = this.attr("estimate");
    const priority = this.attr("priority");
    const s = STATUS[status] || STATUS.todo;
    const body = this.attr("title") ? this.body : "";

    return html`
      <div class="card">
        <div class="head">
          ${priority ? html`<span class="prio" data-p=${priority} title=${`priority: ${priority}`}></span>` : ""}
          <span class="title">${title}</span>
          <span class="pill" data-tone=${s.tone}>${s.label}</span>
        </div>
        ${body ? html`<div class="body">${body}</div>` : ""}
        <div class="meta">
          ${assignee ? html`<span class="who" title=${assignee}><span class="avatar">${initials(assignee)}</span>${assignee}</span>` : ""}
          ${fieldRow("due", due)}
          ${fieldRow("est", estimate)}
        </div>
      </div>`;
  }
}

define("work-task", WorkTask);
