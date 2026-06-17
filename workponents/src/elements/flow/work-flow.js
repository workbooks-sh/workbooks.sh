// <work-flow> — THE runnable orchestration DAG (spine). Its light-DOM children ARE the
// flow definition (composition-as-source) — the *work*: an <ol> runs in sequence, a <ul>
// runs in parallel, nesting is a sub-flow, each leaf step carries a <work-src> that the
// flow executes through the Dock, and a <work-ref rel="when" cond=… to=…> is a conditional
// edge (branch / loop). The element renders its OWN live checklist in shadow DOM — the
// *book*, a view over the work. The light children stay unslotted (the source of truth,
// not shown); the view reflects each step's status as it runs.
//
//   run order   <ol> sequence · <ul> parallel · nesting = sub-flow
//   compute     a leaf's <work-src> → runWith(ctx) (sandbox for js, Dock for compiled)
//   state       a shared `ctx` object threaded across steps (each work-src reads/writes it)
//   control     <work-ref rel="when" cond="<ctxKey>" to="<stepId>"> → if ctx[key], jump there
//   schedule    every="5s|2m|1h" → autorun on an interval · autorun → run once on connect
//
// Emits `work-flow-step { id, ok, output, ctx }` per leaf and `work-flow-done { ctx, ok }`.
// A step with no <work-src> renders but does not run (a presentation step — the flow degrades
// gracefully to a static sequence/board view).
import { WbElement, html, css, define } from "../../core/element.js";
import { bindTriggers } from "../../core/triggers.js";

const MAX_JUMPS = 24;                                  // cap loops (author's guard, like any loop)
const NOT_STEP = /^(WORK-REF|TEMPLATE|SCRIPT|STYLE)$/; // edges/meta are not steps

const stepKids = (c) => Array.from(c.children).filter((el) => !NOT_STEP.test(el.tagName));

function labelOf(el, i) {
  const a = (n) => el.getAttribute && el.getAttribute(n);
  if (a("data-step")) return a("data-step");
  if (a("id")) return a("id");
  if (a("title")) return a("title");
  if (el.tagName === "BOARD-TASK") {
    const t = (el.childNodes[0] && el.childNodes[0].nodeType === 3 ? el.childNodes[0].textContent : "").trim();
    if (t) return t;
  }
  const src = el.tagName === "WORK-SRC" ? el : el.querySelector && el.querySelector(":scope work-src");
  if (src && src.getAttribute("name")) return src.getAttribute("name");
  return `step ${i + 1}`;
}

// parse one authored element into a step descriptor: a group (seq/par) or a leaf.
function parseStep(el, i) {
  const ul = el.tagName === "UL" ? el : el.querySelector && el.querySelector(":scope > ul");
  const ol = el.tagName === "OL" ? el : el.querySelector && el.querySelector(":scope > ol");
  const group = ul || ol;
  const edge = (n) => (el.getAttribute && el.getAttribute(n)) || null;
  const base = { id: labelOf(el, i), el, in: edge("in"), out: edge("out"), deps: edge("deps") };
  if (group) return { ...base, kind: ul ? "par" : "seq", children: stepKids(group).map(parseStep) };
  const src = el.tagName === "WORK-SRC" ? el : el.querySelector && el.querySelector(":scope work-src");
  const w = el.querySelector && el.querySelector(':scope > work-ref[rel="when"]');
  return { ...base, kind: "leaf", src: src || null, lang: src && src.getAttribute("lang"),
           when: w ? { cond: w.getAttribute("cond"), to: w.getAttribute("to") } : null };
}

function chips(label, raw) {
  const items = String(raw || "").split(",").map((x) => x.trim()).filter(Boolean);
  return items.length
    ? html`<span class="edge ${label}"><span class="elabel">${label}</span>${items.map((x) => html`<span class="chip">${x}</span>`)}</span>`
    : "";
}

export class WorkFlow extends WbElement {
  static props = ["name", "every", "at"];
  static properties = { ...WbElement.properties, _status: { state: true }, _busy: { state: true }, _done: { state: true } };

  static styles = css`
    :host { display: block; font-family: var(--work-font); color: var(--work-fg); }
    .shell { border: 1px solid var(--work-border); border-radius: var(--work-radius-lg);
      background: var(--work-surface); overflow: hidden; }
    .head { display: flex; align-items: center; gap: var(--work-space-3);
      padding: var(--work-space-3) var(--work-space-4); border-bottom: 1px solid var(--work-border);
      background: var(--work-surface-soft); }
    .title { font-weight: 700; font-size: var(--work-text-lg); }
    .title .sched { font: var(--work-text-2xs) var(--work-font-mono); color: var(--work-fg-subtle);
      margin-left: var(--work-space-2); }
    .grow { flex: 1; }
    .status { font: var(--work-text-xs)/1 var(--work-font-mono); color: var(--work-fg-muted); }
    button { font: 700 var(--work-text-sm) var(--work-font-mono); cursor: pointer;
      padding: var(--work-space-1) var(--work-space-3); border-radius: var(--work-radius-sm);
      border: 1.5px solid var(--work-border-strong); background: var(--work-fg); color: var(--work-surface); }
    button.ghost { background: transparent; color: var(--work-fg); }
    button:disabled { opacity: .5; cursor: default; }

    .body { padding: var(--work-space-3) var(--work-space-4); display: flex; flex-direction: column; gap: var(--work-space-2); }
    .group { display: flex; flex-direction: column; gap: var(--work-space-2); }
    .group.par > .kids { margin-left: var(--work-space-4);
      border-left: 2px dashed var(--work-border); padding-left: var(--work-space-3); }
    .group > .kids { display: flex; flex-direction: column; gap: var(--work-space-2); }
    .ghead { display: flex; align-items: center; gap: var(--work-space-2); }
    .ghead label { font-weight: 600; font-size: var(--work-text-sm); }
    .ghead .id { font: var(--work-text-2xs) var(--work-font-mono); color: var(--work-fg-subtle); margin-left: auto; }

    .step { border: 1px solid var(--work-border); border-radius: var(--work-radius); background: var(--work-surface);
      padding: var(--work-space-2) var(--work-space-3); transition: border-color .2s, background .2s; }
    .step.running { border-color: var(--work-warn); background: var(--work-warn-soft); }
    .step.done { border-color: var(--work-brand); }
    .step.error { border-color: var(--work-err); background: var(--work-err-soft); }
    .step.done .head label { text-decoration: line-through; color: var(--work-fg-muted); }
    .step .head { display: flex; align-items: center; gap: var(--work-space-2); }
    .step .head input { width: 16px; height: 16px; accent-color: var(--work-brand); }
    .step .head label { font-weight: 600; font-size: var(--work-text-sm); }
    .step .head .tag { font: var(--work-text-2xs) var(--work-font-mono); text-transform: uppercase;
      color: var(--work-brand-ink); background: var(--work-brand-soft); padding: 0 var(--work-space-2);
      border-radius: var(--work-radius-pill); }
    .step .head .id { font: var(--work-text-2xs) var(--work-font-mono); color: var(--work-fg-subtle); margin-left: auto; }
    .out { margin-top: var(--work-space-2); font: var(--work-text-xs)/1.5 var(--work-font-mono);
      color: var(--work-brand-ink); background: var(--work-brand-soft); border-radius: var(--work-radius-sm);
      padding: var(--work-space-1) var(--work-space-2); white-space: pre-wrap; }
    .step.error .out { color: var(--work-err); background: var(--work-err-soft); }

    .edges { display: flex; flex-wrap: wrap; gap: var(--work-space-1) var(--work-space-3); margin-top: var(--work-space-2); }
    .edge { display: inline-flex; align-items: center; gap: var(--work-space-1); flex-wrap: wrap; }
    .elabel { font: var(--work-text-2xs) var(--work-font-mono); text-transform: uppercase; letter-spacing: .05em; color: var(--work-fg-subtle); }
    .chip { font-size: var(--work-text-2xs); font-weight: 600; padding: 1px var(--work-space-2);
      border-radius: var(--work-radius-pill); border: 1px solid var(--work-border); background: var(--work-surface); color: var(--work-fg-muted); }
    .edge.in .chip  { border-color: color-mix(in srgb, var(--work-brand) 35%, transparent); background: var(--work-brand-soft); color: var(--work-brand-ink); }
    .edge.out .chip { border-color: color-mix(in srgb, var(--work-ok) 35%, transparent); background: var(--work-ok-soft); color: var(--work-ok); }

    .ctx { border-top: 1px solid var(--work-border); padding: var(--work-space-3) var(--work-space-4); }
    .ctx h4 { margin: 0 0 var(--work-space-2); font: var(--work-text-2xs) var(--work-font-mono);
      text-transform: uppercase; letter-spacing: .1em; color: var(--work-fg-muted); }
    .ctx pre { margin: 0; font: var(--work-text-xs)/1.5 var(--work-font-mono); color: var(--work-fg);
      background: var(--work-surface-soft); border: 1px solid var(--work-border); border-radius: var(--work-radius-sm);
      padding: var(--work-space-2) var(--work-space-3); overflow: auto; max-height: 260px; }
  `;

  constructor() { super(); this._status = new Map(); this._busy = false; this._done = false; this._ctx = {}; this._tree = { kind: "seq", children: [] }; }

  connectedCallback() {
    super.connectedCallback();
    this._parse();
    this._mo = new MutationObserver(() => { if (!this._busy) { this._parse(); this.requestUpdate(); } });
    this._mo.observe(this, { childList: true, subtree: true, attributes: true, attributeFilter: ["in", "out", "deps", "rel", "cond", "to", "lang"] });
  }
  disconnectedCallback() { super.disconnectedCallback(); this._mo && this._mo.disconnect(); this._unbind && this._unbind(); }

  firstUpdated() {
    const spec = this._triggerSpec();
    if (spec) this._unbind = bindTriggers(this, spec, () => this.run());
  }

  // data-on is the canonical trigger grammar (HTMX hx-trigger, as a valid-HTML data-* attr).
  // every=/autorun are back-compat aliases folded into it: `every 30s` and `load`.
  _triggerSpec() {
    const parts = [];
    if (this.attr("data-on")) parts.push(this.attr("data-on"));
    if (this.attr("every")) parts.push(`every ${this.attr("every")}`);
    if (this.hasAttribute("autorun")) parts.push("load");
    return parts.join(", ");
  }

  /** Parse the light-DOM flow definition into a step tree; mark whether anything runs. */
  _parse() {
    const root = this.querySelector(":scope > ol, :scope > ul") || this;
    this._tree = { kind: root.tagName === "UL" ? "par" : "seq", children: stepKids(root).map(parseStep) };
    this._runnable = !!this.querySelector("work-src");
  }

  _setStatus(id, status, output) {
    const m = new Map(this._status);
    const prev = m.get(id) || {};
    m.set(id, { status, output: output === undefined ? prev.output : output });
    this._status = m;
  }

  /** Run the whole flow from a clean ctx. Public — call it, or wire a button to it. */
  async run() {
    if (this._busy) return;
    this._busy = true; this._done = false; this._ctx = {}; this._status = new Map();
    this.requestUpdate();
    let ok = true;
    try { await this._runNode(this._tree); }
    catch (e) { ok = false; /* a step threw past its own guard */ console.error("[work-flow]", e); }
    this._busy = false; this._done = true; this.requestUpdate();
    this.dispatchEvent(new CustomEvent("work-flow-done", { bubbles: true, composed: true, detail: { ctx: this._ctx, ok } }));
  }
  reset() { this._busy = false; this._done = false; this._ctx = {}; this._status = new Map(); this.requestUpdate(); }

  async _runNode(node) {
    if (node.kind === "par") { await Promise.all(node.children.map((c) => this._runNode(c))); return; }
    if (node.kind === "seq") { await this._runSeq(node.children); return; }
    await this._runLeaf(node);
  }

  // sequence with a conditional jump: after a leaf, if its when-edge's ctx key is truthy,
  // jump to the named step (branch forward / loop back). MAX_JUMPS caps runaway loops.
  async _runSeq(steps) {
    let i = 0, jumps = 0;
    while (i < steps.length) {
      const s = steps[i];
      await this._runNode(s);
      if (s.kind === "leaf" && s.when && this._ctx[s.when.cond] && jumps < MAX_JUMPS) {
        const ti = steps.findIndex((x) => x.id === s.when.to);
        if (ti >= 0) { jumps++; i = ti; continue; }
      }
      i++;
    }
  }

  async _runLeaf(s) {
    if (!s.src) { this._setStatus(s.id, "done"); this.requestUpdate(); return; }  // presentation step
    this._setStatus(s.id, "running"); this.requestUpdate();
    const r = await s.src.runWith(this._ctx);
    this._ctx = r.ctx || this._ctx;
    const out = r.value != null ? r.value : (r.output || "");
    this._setStatus(s.id, r.ok ? "done" : "error", String(out));
    this.requestUpdate();
    this.dispatchEvent(new CustomEvent("work-flow-step", { bubbles: true, composed: true,
      detail: { id: s.id, ok: r.ok, output: String(out), ctx: this._ctx } }));
  }

  _renderNode(node) {
    if (node.children) {
      return html`<div class="group ${node.kind}">
        ${node.id ? html`<div class="ghead"><label>${node.id}</label><span class="id">${node.kind === "par" ? "⫶ parallel" : "sequence"}</span></div>` : ""}
        <div class="kids">${node.children.map((c) => this._renderNode(c))}</div>
      </div>`;
    }
    const st = this._status.get(node.id) || {};
    return html`<div class="step ${st.status || ""}">
      <div class="head">
        <input type="checkbox" disabled .checked=${st.status === "done"}>
        <label>${node.id}</label>
        ${node.lang ? html`<span class="tag">${node.lang}</span>` : ""}
        ${node.when ? html`<span class="id">when ${node.when.cond} → ${node.when.to}</span>` : ""}
      </div>
      ${(node.in || node.out || node.deps) ? html`<div class="edges">${chips("in", node.in)}${chips("out", node.out)}${chips("deps", node.deps)}</div>` : ""}
      ${st.output ? html`<div class="out">⇒ ${st.output}</div>` : ""}
    </div>`;
  }

  render() {
    const name = this.attr("name", "flow");
    const sched = this._triggerSpec();
    const status = this._busy ? "running…" : this._done ? "✓ done" : "idle";
    return html`
      <div class="shell">
        <div class="head">
          <span class="title">${name}${sched ? html`<span class="sched">on ${sched}</span>` : ""}</span>
          <span class="grow"></span>
          ${this._runnable ? html`
            <span class="status">${status}</span>
            <button ?disabled=${this._busy} @click=${() => this.run()}>▶ run</button>
            <button class="ghost" ?disabled=${this._busy} @click=${() => this.reset()}>reset</button>` : ""}
        </div>
        <div class="body">${this._tree.children.map((c) => this._renderNode(c))}</div>
        ${this._runnable && (this._done || this._busy) ? html`
          <div class="ctx"><h4>shared context · ctx</h4><pre>${JSON.stringify(this._ctx, null, 2)}</pre></div>` : ""}
      </div>`;
  }
}

define("work-flow", WorkFlow);
