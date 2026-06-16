// <work-flow> — an agentic flow / pipeline: a titled sequence of steps, where each
// step is a slotted <work-task> (or any child). Composition-as-source: the ordered
// children ARE the flow. The flow surfaces each step's build edges — `in=` / `out=`
// (the data it consumes / produces) and `deps=` (steps it waits on) — as visible
// chips, the same edges the org `#+begin_src` header args once carried, now plain
// attributes (see docs/WORK-FORMAT.md).
//
// The flow reads those edge attributes off its OWN children to render the wiring,
// so the structure is legible in the document without a separate graph model. It is
// pure presentation: it does not execute anything and does not read a clock — firing
// is the host's job.
//
// Attributes (on <work-flow>):
//   title   the flow name
//   in      what the whole flow consumes (visible chip)
//   out     what the whole flow produces (visible chip)
//   deps    other flows/loops it depends on (comma list, visible chips)
//
// Each slotted step may carry its own `in` / `out` / `deps` (+ the pm task attrs),
// which the flow renders inline beside the step.
import { WbElement, html, css, define } from "../../core/element.js";
import { fieldRow, metaCss } from "../pm/pm-shared.js";

function chips(label, raw) {
  const items = String(raw || "").split(",").map((x) => x.trim()).filter(Boolean);
  return items.length
    ? html`<span class="edge"><span class="elabel">${label}</span>${items.map((i) => html`<span class="chip">${i}</span>`)}</span>`
    : "";
}

export class WorkFlow extends WbElement {
  static props = ["title", "in", "out", "deps"];

  static styles = css`
    :host { display: block; font-family: var(--work-font); color: var(--work-fg); }
    .shell { border: 1px solid var(--work-border); border-radius: var(--work-radius-lg); background: var(--work-surface); overflow: hidden; }
    .head { display: flex; flex-direction: column; gap: var(--work-space-2);
      padding: var(--work-space-3) var(--work-space-4); border-bottom: 1px solid var(--work-border); background: var(--work-surface-soft); }
    .title { font-weight: 700; font-size: var(--work-text-lg); }
    .edges { display: flex; flex-wrap: wrap; gap: var(--work-space-2) var(--work-space-3); }
    .edge { display: inline-flex; align-items: center; gap: var(--work-space-1); flex-wrap: wrap; }
    .elabel { font-family: var(--work-font-mono); font-size: var(--work-text-2xs); text-transform: uppercase; letter-spacing: .05em; color: var(--work-fg-subtle); }
    .chip { font-size: var(--work-text-2xs); font-weight: 600; padding: 1px var(--work-space-2);
      border-radius: var(--work-radius-pill); border: 1px solid var(--work-border);
      background: var(--work-surface); color: var(--work-fg-muted); }
    .edge.in .chip  { border-color: color-mix(in srgb, var(--work-brand) 35%, transparent); background: var(--work-brand-soft); color: var(--work-brand-ink); }
    .edge.out .chip { border-color: color-mix(in srgb, var(--work-ok) 35%, transparent);   background: var(--work-ok-soft);   color: var(--work-ok); }

    .steps { display: flex; flex-direction: column; }
    .step { display: flex; gap: var(--work-space-3); padding: var(--work-space-3) var(--work-space-4); border-bottom: 1px solid var(--work-border); }
    .step:last-child { border-bottom: 0; }
    .rail { display: flex; flex-direction: column; align-items: center; flex: none; }
    .num { display: inline-grid; place-items: center; width: 22px; height: 22px; border-radius: var(--work-radius-pill);
      background: var(--work-surface-soft); border: 1px solid var(--work-border); color: var(--work-fg-muted);
      font-family: var(--work-font-mono); font-size: var(--work-text-2xs); font-weight: 700; }
    .line { width: 1.5px; flex: 1 1 auto; background: var(--work-border); margin-top: 2px; }
    .step:last-child .line { display: none; }
    .stepbody { flex: 1 1 auto; display: flex; flex-direction: column; gap: var(--work-space-2); }
    ::slotted(*) { display: block; }
    ${metaCss}
  `;

  static properties = { ...WbElement.properties, _steps: { state: true } };

  constructor() { super(); this._steps = []; }

  connectedCallback() {
    super.connectedCallback();
    this._collect();
    this._mo = new MutationObserver(() => this._collect());
    this._mo.observe(this, { childList: true, attributes: true, attributeFilter: ["in", "out", "deps"], subtree: true });
  }
  disconnectedCallback() { super.disconnectedCallback(); this._mo?.disconnect(); }

  /** Read the edge attrs off each child step + slot it into a numbered band. */
  _collect() {
    const kids = Array.from(this.children);
    this._steps = kids.map((el, i) => {
      el.setAttribute("slot", `step-${i}`);
      return {
        i,
        in: el.getAttribute("in"),
        out: el.getAttribute("out"),
        deps: el.getAttribute("deps"),
      };
    });
    this.requestUpdate();
  }

  render() {
    const title = this.attr("title", "Flow");
    return html`
      <div class="shell">
        <div class="head">
          <span class="title">${title}</span>
          <div class="edges">
            <span class="edge in">${chips("in", this.attr("in"))}</span>
            <span class="edge out">${chips("out", this.attr("out"))}</span>
            ${chips("deps", this.attr("deps"))}
          </div>
        </div>
        <div class="steps">
          ${this._steps.map((s) => html`
            <div class="step">
              <div class="rail"><span class="num">${s.i + 1}</span><span class="line"></span></div>
              <div class="stepbody">
                <slot name=${`step-${s.i}`}></slot>
                ${(s.in || s.out || s.deps) ? html`<div class="edges">
                  <span class="edge in">${chips("in", s.in)}</span>
                  <span class="edge out">${chips("out", s.out)}</span>
                  ${chips("deps", s.deps)}
                </div>` : ""}
              </div>
            </div>`)}
        </div>
      </div>`;
  }
}

define("work-flow", WorkFlow);
