// <board-sprint> — a time-boxed iteration: a titled interval (start=…end=…) that
// contains its work. Composition-as-source: slotted <board-task> children ARE the
// sprint backlog; the sprint renders its interval header + a done/total progress
// bar computed from the children's `status`, then slots the tasks below.
//
// Time is host-injected: the sprint displays the `start`/`end` interval values it
// is authored with and does pure presentation. It does NOT read a clock to decide
// "is this sprint active" — that comparison against an injected `now` is the host's
// job (see docs/WORK-FORMAT.md, Time).
//
// Attributes:
//   title   sprint name
//   start   ISO-8601 instant — interval start
//   end     ISO-8601 instant — interval end
import { WbElement, html, css, define } from "../../core/element.js";
import { fieldRow, metaCss } from "./pm-shared.js";

export class WorkSprint extends WbElement {
  static props = ["title", "start", "end"];

  static styles = css`
    :host { display: block; font-family: var(--work-font); color: var(--work-fg); }
    .shell { border: 1px solid var(--work-border); border-radius: var(--work-radius-lg); background: var(--work-surface); overflow: hidden; }
    .head { display: flex; flex-direction: column; gap: var(--work-space-2);
      padding: var(--work-space-3) var(--work-space-4); border-bottom: 1px solid var(--work-border); background: var(--work-surface-soft); }
    .row { display: flex; align-items: center; gap: var(--work-space-3); }
    .title { font-weight: 700; font-size: var(--work-text-lg); flex: 1 1 auto; }
    .progress { position: relative; height: 6px; border-radius: var(--work-radius-pill); background: var(--work-surface); overflow: hidden; border: 1px solid var(--work-border); }
    .progress > i { position: absolute; inset: 0 auto 0 0; width: var(--_pct, 0%); background: var(--work-ok); transition: width var(--work-dur) var(--work-ease); }
    .pct { font-family: var(--work-font-mono); font-size: var(--work-text-2xs); color: var(--work-fg-muted); white-space: nowrap; }
    .body { display: flex; flex-direction: column; gap: var(--work-space-2); padding: var(--work-space-3) var(--work-space-4); }
    ${metaCss}
  `;

  static properties = { ...WbElement.properties, _done: { state: true }, _total: { state: true } };

  constructor() { super(); this._done = 0; this._total = 0; }

  connectedCallback() {
    super.connectedCallback();
    this._tally();
    this._mo = new MutationObserver(() => this._tally());
    this._mo.observe(this, { childList: true, attributes: true, attributeFilter: ["status"], subtree: false });
  }
  disconnectedCallback() { super.disconnectedCallback(); this._mo?.disconnect(); }

  _tally() {
    const tasks = Array.from(this.querySelectorAll(":scope > board-task"));
    this._total = tasks.length;
    this._done = tasks.filter((t) => t.getAttribute("status") === "done").length;
    this.requestUpdate();
  }

  render() {
    const title = this.attr("title", "Sprint");
    const start = this.attr("start");
    const end = this.attr("end");
    const pct = this._total ? Math.round((this._done / this._total) * 100) : 0;
    return html`
      <div class="shell">
        <div class="head">
          <div class="row">
            <span class="title">${title}</span>
            <span class="pct">${this._done}/${this._total}</span>
          </div>
          <div class="progress" style=${`--_pct:${pct}%`} role="progressbar" aria-valuenow=${pct}><i></i></div>
          <div class="meta">${fieldRow("start", start)}${fieldRow("end", end)}</div>
        </div>
        <div class="body"><slot></slot></div>
      </div>`;
  }
}

define("board-sprint", WorkSprint);
