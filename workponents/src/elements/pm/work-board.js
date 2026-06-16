// <work-board> — a Kanban board. Composition-as-source: its slotted <work-task>
// children ARE the board; the board groups them into status columns by reading
// each task's `status` attribute (no JSON model — the elements are the truth).
//
// Each column is a named slot (slot="status-<key>"); on connect and on any child
// mutation the board assigns every <work-task> to the slot matching its status,
// so authors just drop tasks in any order and the board lays them out. A column
// header shows the status label + a live count.
//
// Attributes:
//   title    optional board heading
//   columns  comma-separated status keys to show (default: todo,doing,review,done,blocked)
import { WbElement, html, css, define } from "../../core/element.js";
import { STATUS, STATUS_ORDER, metaCss } from "./pm-shared.js";

export class WorkBoard extends WbElement {
  static props = ["title", "columns"];

  static styles = css`
    :host { display: block; font-family: var(--work-font); color: var(--work-fg); }
    .title { font-weight: 700; font-size: var(--work-text-lg); margin-bottom: var(--work-space-3); }
    .cols { display: grid; grid-auto-flow: column; grid-auto-columns: minmax(200px, 1fr); gap: var(--work-space-3); overflow-x: auto; align-items: start; }
    .col { display: flex; flex-direction: column; gap: var(--work-space-2);
      background: var(--work-surface-soft); border: 1px solid var(--work-border);
      border-radius: var(--work-radius-lg); padding: var(--work-space-3); min-height: 60px; }
    .chead { display: flex; align-items: center; gap: var(--work-space-2); }
    .clabel { font-weight: 600; font-size: var(--work-text-sm); }
    .count { margin-left: auto; font-family: var(--work-font-mono); font-size: var(--work-text-2xs);
      color: var(--work-fg-subtle); background: var(--work-surface); border: 1px solid var(--work-border);
      border-radius: var(--work-radius-pill); padding: 0 var(--work-space-2); }
    ::slotted(work-task) { margin-bottom: var(--work-space-2); }
    .dot { width: 8px; height: 8px; border-radius: var(--work-radius-pill); flex: none; background: var(--work-fg-subtle); }
    .dot[data-tone="brand"] { background: var(--work-brand); }
    .dot[data-tone="ok"] { background: var(--work-ok); }
    .dot[data-tone="warn"] { background: var(--work-warn); }
    .dot[data-tone="err"] { background: var(--work-err); }
    ${metaCss}
  `;

  static properties = { ...WbElement.properties, _counts: { state: true } };

  constructor() { super(); this._counts = {}; }

  connectedCallback() {
    super.connectedCallback();
    this._assign();
    this._mo = new MutationObserver(() => this._assign());
    this._mo.observe(this, { childList: true, subtree: false, attributes: true, attributeFilter: ["status"] });
  }
  disconnectedCallback() { super.disconnectedCallback(); this._mo?.disconnect(); }

  _columns() {
    const raw = this.attr("columns");
    return raw ? raw.split(",").map((c) => c.trim()).filter(Boolean) : STATUS_ORDER;
  }

  /** Route each <work-task> into the slot for its status; recompute counts. */
  _assign() {
    const cols = this._columns();
    const counts = Object.fromEntries(cols.map((c) => [c, 0]));
    for (const task of this.querySelectorAll(":scope > work-task")) {
      let status = task.getAttribute("status") || "todo";
      if (!cols.includes(status)) status = cols[0];
      task.setAttribute("slot", `status-${status}`);
      counts[status] = (counts[status] || 0) + 1;
    }
    this._counts = counts;
    this.requestUpdate();
  }

  render() {
    const title = this.attr("title");
    const cols = this._columns();
    return html`
      ${title ? html`<div class="title">${title}</div>` : ""}
      <div class="cols">
        ${cols.map((c) => {
          const s = STATUS[c] || { label: c, tone: "neutral" };
          return html`<div class="col">
            <div class="chead">
              <span class="dot" data-tone=${s.tone}></span>
              <span class="clabel">${s.label}</span>
              <span class="count">${this._counts[c] || 0}</span>
            </div>
            <slot name=${`status-${c}`}></slot>
          </div>`;
        })}
      </div>`;
  }
}

define("work-board", WorkBoard);
