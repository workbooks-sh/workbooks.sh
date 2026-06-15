// <wb-undo> — undo the last change (the "undo anything an agent did" promise).
// git's reflog / jj op-log reinvented as one verb: undo the most recent Change
// to a scope. Itself append-only at the ledger level (mirrors History.undo/2,
// which rides the append-only Restore — see jj.ex for the op-log substrate).
//
// Attrs: `scope` (workbook id), `label`. Capability via `this.host`: POSTs the
// undo when a runtime is configured; standalone it emits `undo` {detail:{scope}}
// for the host page. Always emits `undo` on success.
import { WbElement, define } from "../../core/element.js";

const esc = (s) => String(s).replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]));

export class WbUndo extends WbElement {
  static props = ["scope", "label", "disabled", "busy"];

  static styles = `
    :host { display: inline-block; font-family: var(--wb-font); }
    button {
      display: inline-flex; align-items: center; gap: var(--wb-space-2);
      font: 600 var(--wb-text) var(--wb-font); line-height: 1;
      padding: var(--wb-space-2) var(--wb-space-4);
      border-radius: var(--wb-radius); cursor: pointer;
      background: var(--wb-surface-soft); color: var(--wb-fg);
      border: 1.5px solid var(--wb-border);
      transition: background var(--wb-dur) var(--wb-ease), transform var(--wb-dur) var(--wb-ease);
    }
    button:hover { background: var(--wb-surface); border-color: var(--wb-border-strong); transform: translateY(-1px); }
    button:active { transform: translateY(0); }
    button:focus-visible { outline: none; box-shadow: 0 0 0 3px var(--wb-ring); }
    svg { width: 15px; height: 15px; }
    :host([disabled]) button, :host([busy]) button { opacity: .5; pointer-events: none; }
    :host([busy]) svg { animation: spin .8s linear infinite; }
    @keyframes spin { to { transform: rotate(360deg); } }
  `;

  connectedCallback() {
    super.connectedCallback();
    this.addEventListener("click", () => this.undo());
  }

  async undo() {
    if (this.boolAttr("disabled") || this.boolAttr("busy")) return;
    const scope = this.attr("scope");
    const detail = { scope };
    this.setAttribute("busy", "");
    try {
      if (this.host.available("runtime") && scope) {
        detail.result = await this.host.request("/history/undo", { body: { scope } });
      }
      this.dispatchEvent(new CustomEvent("undo", { bubbles: true, composed: true, detail }));
    } catch (err) {
      this.dispatchEvent(new CustomEvent("undo-error", { bubbles: true, composed: true, detail: { ...detail, error: String(err) } }));
    } finally {
      this.removeAttribute("busy");
    }
  }

  render() {
    const label = this.attr("label", "Undo last change");
    return `<button part="button" aria-label="${esc(label)}">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
        <path d="M9 14 4 9l5-5"/><path d="M4 9h11a6 6 0 0 1 0 12h-3"/>
      </svg>
      <span>${esc(label)}</span>
    </button>`;
  }
}

define("wb-undo", WbUndo);
