// <work-src> — THE compute primitive (spine). Inline source in some `lang`, compiled
// by the Dock to a sandboxed WASM module. The source IS the element's text content
// (composition-as-source). This is the canonical block that code-repl / document-cell
// are views over.
//
// Routing (mirrors code-repl, the one Dock contract):
//   • host.available("compile") → POST /run { language, source } → { ok, output }.
//     Any language through the compiler lane (clang/rustc/zig/go/StarlingMonkey → wasm).
//   • standalone JS → sandboxed Worker (sandbox.js · never eval in the page).
//   • compiled langs with no runtime → an honest "runtime needed" state, never a fake.
//
// Attributes:
//   lang      python|rust|c|zig|js|sql … (routes the Dock lane)
//   name      exports the module as a callable under this name
//   display   table|raw → run on connect and render the result inline (the
//             document-cell collapse); absent → show source + a Run affordance.
//
// Emits `work-run { lang, name, ok, output }` after every run.
import { WbElement, html, css, define } from "../../core/element.js";
import { runJs } from "../code/sandbox.js";
import { bindTriggers } from "../../core/triggers.js";

const STANDALONE = new Set(["js", "javascript"]);
const norm = (l) => String(l || "js").toLowerCase().trim();

export class WorkSrc extends WbElement {
  static props = ["lang", "name", "display"];

  static styles = css`
    :host { display: block; font-family: var(--work-font); color: var(--work-fg); }
    .shell { border: 1px solid var(--work-border); border-radius: var(--work-radius-lg);
      background: var(--work-surface); overflow: hidden; }
    .head { display: flex; align-items: center; gap: var(--work-space-2);
      padding: var(--work-space-2) var(--work-space-3); border-bottom: 1px solid var(--work-border);
      background: var(--work-surface-soft); }
    .lang { font-family: var(--work-font-mono); font-weight: 700; font-size: var(--work-text-sm);
      text-transform: uppercase; letter-spacing: .06em; color: var(--work-brand-ink);
      background: var(--work-brand-soft); padding: var(--work-space-2px) var(--work-space-2); border-radius: var(--work-radius-pill); }
    .name { font-family: var(--work-font-mono); font-size: var(--work-text-sm); color: var(--work-fg-muted); }
    .grow { flex: 1; }
    button { font: 700 var(--work-text-sm) var(--work-font-mono); cursor: pointer;
      padding: var(--work-space-1) var(--work-space-3); border-radius: var(--work-radius-sm); border: 1.5px solid var(--work-border-strong);
      background: var(--work-fg); color: var(--work-surface); }
    button:disabled { opacity: .5; cursor: default; }
    pre { margin: 0; padding: var(--work-space-3); overflow: auto;
      font: var(--work-text-sm)/1.6 var(--work-font-mono); color: var(--work-fg); white-space: pre; }
    .out { border-top: 1px solid var(--work-border); padding: var(--work-space-3);
      font: var(--work-text-sm)/1.6 var(--work-font-mono); white-space: pre-wrap; }
    .out.err { color: var(--work-err); }
    .out .badge { display: inline-block; font-size: var(--work-text-sm); color: var(--work-fg-subtle);
      border: 1px solid var(--work-border); border-radius: var(--work-radius-pill); padding: 0 var(--work-space-2); }
  `;

  constructor() {
    super();
    this._out = null;
    this._running = false;
  }

  get lang() { return norm(this.attr("lang", "js")); }
  get source() { return (this.textContent || "").trim(); }
  get canRun() { return this.host.available("compile") || STANDALONE.has(this.lang); }

  firstUpdated() {
    if (this.attr("display")) this._run();   // display= → run-and-render (document-cell behaviour)
    if (this.attr("w-on")) this._unbind = bindTriggers(this, this.attr("w-on"), () => this._run());
  }
  disconnectedCallback() { super.disconnectedCallback(); this._unbind && this._unbind(); }

  // The execution seam — the SAME Dock routing for the standalone Run button and for
  // a <work-flow> orchestrating this node. `ctx` is the shared flow context: JS threads
  // it through the sandbox (serialized in/out, isolation intact); compiled langs pass it
  // to the Dock /run as input. Returns { ok, output, value, ctx } — `value` is the step's
  // return (what a flow chains on), `output` is the formatted log/result pane.
  async runWith(ctx = {}) {
    const lang = this.lang, source = this.source;
    try {
      if (STANDALONE.has(lang)) {
        const r = await runJs(source, { ctx });
        return { ok: r.ok, output: r.output, value: r.value, ctx: r.ctx ?? ctx };
      }
      if (this.host.available("compile")) {
        const r = await this.host.request("/run", { body: { language: lang, source, ctx } });
        return { ok: !!(r && r.ok), output: (r && (r.output ?? r.stdout)) || "",
                 value: r && r.value, ctx: (r && r.ctx) || ctx };
      }
      return { ok: false, ctx,
               output: `${lang} compiles to WASM through the Dock — connect a runtime to run it.` };
    } catch (e) {
      return { ok: false, output: "run failed: " + (e.message || e), ctx };
    }
  }

  async _run() {
    if (this._running) return;
    this._running = true; this.requestUpdate();
    const res = await this.runWith({});
    this._out = res;
    this._running = false;
    this.requestUpdate();
    this.dispatchEvent(new CustomEvent("work-run", {
      bubbles: true, composed: true,
      detail: { lang: this.lang, name: this.attr("name") || null, ok: res.ok, output: res.output },
    }));
  }

  render() {
    const name = this.attr("name");
    return html`
      <div class="shell">
        <div class="head">
          <span class="lang">${this.lang}</span>
          ${name ? html`<span class="name">${name}</span>` : ""}
          <span class="grow"></span>
          <button ?disabled=${this._running || !this.canRun}
            title=${this.canRun ? "" : "needs a runtime"} @click=${() => this._run()}>
            ${this._running ? "running…" : "run"}
          </button>
        </div>
        <pre><code>${this.source}</code></pre>
        ${this._out
          ? html`<div class="out ${this._out.ok ? "" : "err"}">
              <span class="badge">${this._out.ok ? "→ WASM · Dock" : "needs runtime"}</span>
              ${this._out.output ? html`\n${this._out.output}` : ""}
            </div>`
          : ""}
      </div>`;
  }
}

define("work-src", WorkSrc);
