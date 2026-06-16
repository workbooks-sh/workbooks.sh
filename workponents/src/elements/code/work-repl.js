// <work-repl> — a <work-editor> + a Run affordance + an output pane. Real in-sandbox
// eval: composition-as-source code, run where it can actually run.
//
//   • host.available("compile") → route ANY language through the Host compiler
//     lane (clang/rustc/zig/go/StarlingMonkey → wasm), in-sandbox. Endpoint
//     contract: POST /run { language, source } → { ok, output }. Mirrors how
//     <work-doc-cell> routes compute through `this.host` and degrades cleanly.
//   • STANDALONE (no runtime) → JS evals in a sandboxed Worker (never eval in the
//     page; see sandbox.js). Compiled languages show a clear, themed
//     "runtime needed for C/Rust/Zig/Go" state instead of pretending.
//
// Emits `work-run {language, ok, output}` after every run.
import { WbElement, html, css, define } from "../../core/element.js";
import { defineVariants, variantAttrs } from "../../core/variants.js";
import { normalizeLang } from "./highlight.js";
import { runJs } from "./sandbox.js";
import "./work-editor.js";

const VARIANTS = defineVariants({
  variant: { options: ["card", "inline"], default: "card" },
});

// Languages the standalone floor can actually run (no compiler lane needed).
const STANDALONE_RUNNABLE = new Set(["js"]);
const COMPILED = { c: "C", cpp: "C", rust: "Rust", zig: "Zig", go: "Go" };

export class WorkRepl extends WbElement {
  static variants = VARIANTS;
  static props = [...variantAttrs(VARIANTS), "language", "gutter"];

  static properties = {
    ...WbElement.properties,
    _busy: { state: true },
    _result: { state: true },
    _live: { state: true },
  };

  static styles = css`
    :host { display: block; font-family: var(--work-font); }
    .shell { border: 1px solid var(--work-border); border-radius: var(--work-radius);
      background: var(--work-surface); overflow: hidden; box-shadow: var(--work-shadow-sm); }
    :host([variant="inline"]) .shell { border: none; box-shadow: none; background: transparent; }

    .bar { display: flex; align-items: center; gap: var(--work-space-2);
      padding: var(--work-space-2) var(--work-space-3); border-bottom: 1px solid var(--work-border);
      background: var(--work-surface-soft); }
    .lang { font-family: var(--work-font-mono); font-weight: 700; font-size: var(--work-text-sm);
      text-transform: uppercase; letter-spacing: 0.06em; color: var(--work-brand); }
    .where { font-family: var(--work-font-mono); font-size: var(--work-text-sm); color: var(--work-fg-subtle);
      display: inline-flex; align-items: center; gap: var(--work-space-1); }
    .where .dot { width: 7px; height: 7px; border-radius: var(--work-radius-pill);
      background: var(--work-warn); box-shadow: 0 0 0 var(--work-space-3px) var(--work-warn-glow); }
    .where[data-live="1"] .dot { background: var(--work-brand); box-shadow: 0 0 0 3px var(--work-brand-soft); }
    .run { margin-left: auto; font-family: var(--work-font); font-weight: 600; font-size: var(--work-text-sm);
      display: inline-flex; align-items: center; gap: var(--work-space-2);
      padding: var(--work-space-2) var(--work-space-4); border-radius: var(--work-radius-sm);
      border: 1.5px solid transparent; background: var(--work-brand); color: var(--work-on-brand); cursor: pointer;
      transition: transform var(--work-dur) var(--work-ease), opacity var(--work-dur) var(--work-ease); }
    .run:hover { transform: translateY(-1px); }
    .run:active { transform: translateY(0); }
    .run:focus-visible { outline: none; box-shadow: 0 0 0 3px var(--work-ring); }
    .run[disabled] { opacity: 0.55; cursor: not-allowed; }
    .run .tri { width: 0; height: 0; border-left: 7px solid currentColor;
      border-top: 5px solid transparent; border-bottom: 5px solid transparent; }

    .out { border-top: 1px solid var(--work-border); background: var(--work-bg); }
    .out-head { padding: var(--work-space-2) var(--work-space-3); font-family: var(--work-font-mono);
      font-size: var(--work-text-sm); color: var(--work-fg-subtle); text-transform: uppercase;
      letter-spacing: 0.06em; border-bottom: 1px solid var(--work-border); display: flex; gap: var(--work-space-2); }
    .out-head .badge { margin-left: auto; text-transform: none; letter-spacing: 0; font-weight: 600; }
    .out-head .badge.ok { color: var(--work-ok); }
    .out-head .badge.err { color: var(--work-err); }
    pre.console { margin: 0; padding: var(--work-space-3); font-family: var(--work-font-mono);
      font-size: var(--work-text-sm); line-height: 1.6; color: var(--work-fg);
      white-space: pre-wrap; word-break: break-word; max-height: 280px; overflow: auto; }
    pre.console.err { color: var(--work-err); }
    .empty { color: var(--work-fg-subtle); font-style: italic; }

    .note { padding: var(--work-space-3); display: flex; gap: var(--work-space-3); align-items: flex-start;
      background: var(--work-surface-soft); }
    .note .ic { flex: none; width: 22px; height: 22px; border-radius: var(--work-radius-pill);
      background: var(--work-warn-fill); color: var(--work-warn); display: grid; place-items: center;
      font-weight: 700; font-family: var(--work-font-mono); }
    .note .body { font-size: var(--work-text-sm); line-height: 1.5; color: var(--work-fg-muted); }
    .note .body b { color: var(--work-fg); }
    .note code { font-family: var(--work-font-mono); color: var(--work-fg); background: var(--work-bg);
      padding: var(--work-space-px) var(--work-space-5px); border-radius: var(--work-radius-sm); }
  `;

  constructor() {
    super();
    this._busy = false;
    this._result = null;
    this._live = false;
  }

  get language() { return normalizeLang(this.attr("language", "js")); }

  connectedCallback() {
    if (this._source == null) {
      this._source = this.attr("value") != null ? this.attr("value")
        : (this.textContent || "").replace(/^\n/, "").replace(/\s+$/, "");
    }
    super.connectedCallback();
  }

  // can this language run AT ALL in the current context?
  _runnable() {
    if (this.host.available("compile")) return true;
    return STANDALONE_RUNNABLE.has(this.language);
  }

  async _run() {
    if (this._busy || !this._runnable()) return;
    const language = this.language;
    const source = this._editorValue();
    this._busy = true;
    let res;
    try {
      if (this.host.available("compile")) {
        // compiler lane: language → compile + run in-sandbox, server-side.
        const r = await this.host.request("/run", { body: { language, source } });
        res = { ok: !!(r && r.ok), output: (r && (r.output ?? r.stdout)) || "" };
        this._live = true;
      } else {
        res = await runJs(source);
        this._live = false;
      }
    } catch (e) {
      res = { ok: false, output: "run failed: " + (e.message || e) };
    }
    this._busy = false;
    this._result = res;
    this.dispatchEvent(new CustomEvent("work-run", {
      detail: { language, ok: res.ok, output: res.output },
      bubbles: true, composed: true,
    }));
  }

  _editorValue() {
    const ed = this.shadowRoot.querySelector("work-editor");
    return ed ? ed.value : this._source;
  }

  _onCodeChange(e) { this._source = e.detail.value; }

  _renderOut() {
    const language = this.language;
    const compiled = COMPILED[language];
    const canRun = this._runnable();

    // graceful "needs runtime" state for compiled languages standalone
    if (!canRun && compiled) {
      return html`
        <div class="note">
          <span class="ic">!</span>
          <div class="body">
            <b>${compiled} needs the runtime.</b> Standalone, this editor runs
            JavaScript in a sandbox. Compiling and running ${compiled} (and Rust /
            Zig / Go) routes through the Workbooks compiler lane — connect a runtime
            (<code>host.available("compile")</code>) and the same code runs in-sandbox, no setup.
          </div>
        </div>`;
    }

    const r = this._result;
    const badge = this._busy ? "" : r
      ? html`<span class="badge ${r.ok ? "ok" : "err"}">${r.ok ? "ok" : "error"}</span>`
      : "";
    let body;
    if (this._busy) body = html`<pre class="console"><span class="empty">running…</span></pre>`;
    else if (!r) body = html`<pre class="console"><span class="empty">output appears here — press Run</span></pre>`;
    else body = html`<pre class="console${r.ok ? "" : " err"}">${r.output ? r.output : html`<span class="empty">(no output)</span>`}</pre>`;

    return html`
      <div class="out">
        <div class="out-head"><span>output</span>${badge}</div>
        ${body}
      </div>`;
  }

  render() {
    const language = this.language;
    const canRun = this._runnable();
    const live = this.host.available("compile");
    const where = live ? "compiler lane" : (canRun ? "sandbox (worker)" : "needs runtime");
    const gutter = this.attr("gutter");
    return html`
      <div class="shell">
        <div class="bar">
          <span class="lang">${language}</span>
          <span class="where" data-live=${live ? 1 : 0}><span class="dot"></span>${where}</span>
          <button class="run" type="button" ?disabled=${!canRun} @click=${() => this._run()}>
            <span class="tri"></span>${this._busy ? "running" : "Run"}
          </button>
        </div>
        <work-editor language=${language} gutter=${gutter ?? ""} variant="inline"
          @work-code-change=${(e) => this._onCodeChange(e)}>${this._source || ""}</work-editor>
        ${this._renderOut()}
      </div>`;
  }
}

define("work-repl", WorkRepl);
