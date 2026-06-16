// <board-milestone> — a dated marker: a goal due on an instant, either reached
// (done) or pending. Renders its own attributes as a compact marker row with a
// check/target glyph, the title, a due chip and a status pill.
//
// Time is host-injected: the milestone displays its `due` value as-authored and
// does pure presentation. Whether it is overdue relative to "now" is the host's
// comparison (now is a parameter, never a clock read — docs/WORK-FORMAT.md).
//
// Attributes:
//   title   what the milestone marks
//   due     ISO-8601 instant it is due
//   done    boolean — present when reached
import { WbElement, html, css, define } from "../../core/element.js";
import { fieldRow, pill, metaCss } from "./pm-shared.js";

export class WorkMilestone extends WbElement {
  static props = ["title", "due", "done"];

  static styles = css`
    :host { display: block; font-family: var(--work-font); color: var(--work-fg); }
    .row { display: flex; align-items: center; gap: var(--work-space-3);
      padding: var(--work-space-2) var(--work-space-3);
      border: 1px solid var(--work-border); border-radius: var(--work-radius); background: var(--work-surface); }
    .marker { display: inline-grid; place-items: center; width: 22px; height: 22px; border-radius: var(--work-radius-pill);
      border: 1.5px solid var(--work-border-strong); color: var(--work-fg-subtle); flex: none; }
    :host([done]) .marker { border-color: var(--work-ok); color: var(--work-ok); background: var(--work-ok-soft); }
    .glyph { width: 13px; height: 13px; }
    .title { font-weight: 600; flex: 1 1 auto; }
    :host([done]) .title { color: var(--work-fg-muted); }
    ${metaCss}
  `;

  render() {
    const done = this.boolAttr("done");
    const title = this.attr("title", "Milestone");
    const due = this.attr("due");
    const d = done
      ? "M20 6 9 17l-5-5"
      : "M12 22a10 10 0 100-20 10 10 0 000 20zM12 8v4l3 3";
    return html`
      <div class="row">
        <span class="marker">
          <svg class="glyph" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d=${d}></path></svg>
        </span>
        <span class="title">${title}</span>
        <span class="meta">${fieldRow("due", due)}</span>
        ${pill(done ? "done" : "todo")}
      </div>`;
  }
}

define("board-milestone", WorkMilestone);
