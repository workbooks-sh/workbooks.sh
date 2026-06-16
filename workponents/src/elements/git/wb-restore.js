// <work-restore> — APPEND-ONLY restore (the "nothing is lost, restore anything"
// promise). git's `checkout`/`reset` reinvented as one safe verb: restoring a
// version never rewinds — it re-applies an old version AS A NEW version, so the
// timeline stays fully intact (mirrors History.restore/3 in history.ex).
//
// Attrs: `scope` (workbook id), `to` (the version id to restore). Capability via
// `this.host`: when a runtime is configured it POSTs the restore; standalone it
// just emits `restore` {detail:{scope, to}} for the host page to handle. Always
// emits `restore` after a successful call so either wiring drives the UI.
import { WbElement, html, css, define } from "../../core/element.js";

export class WorkRestore extends WbElement {
  static props = ["scope", "to", "label", "disabled", "busy"];

  static styles = css`
    :host { display: inline-block; font-family: var(--work-font); }
    button {
      display: inline-flex; align-items: center; gap: var(--work-space-2);
      font: 600 var(--work-text) var(--work-font); line-height: 1;
      padding: var(--work-space-2) var(--work-space-4);
      border-radius: var(--work-radius); cursor: pointer;
      background: transparent; color: var(--work-fg);
      border: 1.5px solid var(--work-border-strong);
      transition: background var(--work-dur) var(--work-ease), border-color var(--work-dur) var(--work-ease), transform var(--work-dur) var(--work-ease);
    }
    button:hover { background: var(--work-surface-soft); transform: translateY(-1px); }
    button:active { transform: translateY(0); }
    button:focus-visible { outline: none; box-shadow: 0 0 0 3px var(--work-ring); }
    svg { width: 15px; height: 15px; }
    :host([disabled]) button, :host([busy]) button { opacity: .5; pointer-events: none; }
    :host([busy]) svg { animation: spin .8s linear infinite; }
    @keyframes spin { to { transform: rotate(360deg); } }
  `;

  async restore() {
    if (this.boolAttr("disabled") || this.boolAttr("busy")) return;
    const scope = this.attr("scope"), to = this.attr("to");
    const detail = { scope, to };
    this.setAttribute("busy", "");
    try {
      if (this.host.available("runtime") && scope && to) {
        const res = await this.host.request("/history/restore", { body: { scope, to } });
        detail.result = res;
      }
      this.dispatchEvent(new CustomEvent("restore", { bubbles: true, composed: true, detail }));
    } catch (err) {
      this.dispatchEvent(new CustomEvent("restore-error", { bubbles: true, composed: true, detail: { ...detail, error: String(err) } }));
    } finally {
      this.removeAttribute("busy");
    }
  }

  render() {
    const label = this.attr("label", "Restore this version");
    return html`<button part="button" aria-label=${label} @click=${() => this.restore()}>
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
        <path d="M3 12a9 9 0 1 0 3-6.7L3 8"/><path d="M3 3v5h5"/>
      </svg>
      <span>${label}</span>
    </button>`;
  }
}

define("work-restore", WorkRestore);
