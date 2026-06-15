// <wb-composer> — the conversation input. Emits an intent rather than wiring
// to a transport itself: on submit it dispatches a `wb-intent` CustomEvent
// (bubbles, composed) carrying the typed text; the thread / host decides what
// to do with it (append a turn, call inference over this.host, …). This keeps
// the element transport-agnostic — same element, any provider behind the Dock.
//
// State (the `state` attribute, reflected so :host([state=…]) themes it):
//   idle      — ready for input
//   thinking  — the agent is working (animated indicator, input locked)
//   streaming — a reply is streaming in (animated indicator, input locked)
//
// Usage:
//   <wb-composer placeholder="Message the agent…"></wb-composer>
//   composer.addEventListener("wb-intent", (e) => { … e.detail.text … });
//   composer.setAttribute("state", "thinking");  // host flips it while busy
import { WbElement, define } from "../../core/element.js";
import { defineVariants, variantAttrs } from "../../core/variants.js";

const VARIANTS = defineVariants({
  state: { options: ["idle", "thinking", "streaming"], default: "idle" },
});

export class WbComposer extends WbElement {
  static variants = VARIANTS;
  static props = [...variantAttrs(VARIANTS), "placeholder", "disabled"];

  static styles = `
    :host { display: block; font-family: var(--wb-font); color: var(--wb-fg); }
    .composer {
      display: flex; align-items: flex-end; gap: var(--wb-space-2);
      border: 1.5px solid var(--wb-border-strong);
      border-radius: var(--wb-radius-lg);
      background: var(--wb-surface);
      padding: var(--wb-space-2) var(--wb-space-2) var(--wb-space-2) var(--wb-space-4);
      transition: border-color var(--wb-dur) var(--wb-ease), box-shadow var(--wb-dur) var(--wb-ease);
    }
    .composer:focus-within { border-color: var(--wb-brand); box-shadow: 0 0 0 3px var(--wb-ring); }
    textarea {
      flex: 1; resize: none; border: 0; outline: 0; background: none;
      font: var(--wb-text)/1.5 var(--wb-font); color: var(--wb-fg);
      padding: var(--wb-space-2) 0; max-height: 180px;
    }
    textarea::placeholder { color: var(--wb-fg-subtle); }
    .send {
      display: inline-grid; place-items: center; width: 34px; height: 34px; flex: none;
      border: 0; border-radius: var(--wb-radius); cursor: pointer;
      background: var(--wb-brand); color: var(--wb-on-brand);
      transition: filter var(--wb-dur) var(--wb-ease), opacity var(--wb-dur) var(--wb-ease);
    }
    .send:hover { filter: brightness(1.06); }
    .send:focus-visible { outline: none; box-shadow: 0 0 0 3px var(--wb-ring); }
    .send svg { width: 16px; height: 16px; }

    /* busy states: lock input, show a live indicator in place of the icon */
    :host([state="thinking"]) textarea,
    :host([state="streaming"]) textarea,
    :host([disabled]) textarea { pointer-events: none; opacity: .6; }
    :host([state="thinking"]) .composer,
    :host([state="streaming"]) .composer { border-color: var(--wb-brand); }

    .dots { display: inline-flex; gap: 3px; }
    .dots i { width: 5px; height: 5px; border-radius: 50%; background: currentColor;
      animation: wb-pulse 1s var(--wb-ease) infinite; }
    .dots i:nth-child(2) { animation-delay: .15s; }
    .dots i:nth-child(3) { animation-delay: .3s; }
    @keyframes wb-pulse { 0%,80%,100% { opacity: .25; transform: scale(.8); } 40% { opacity: 1; transform: scale(1); } }

    .status { font: 600 11px var(--wb-font-mono); letter-spacing: .06em;
      text-transform: uppercase; color: var(--wb-fg-muted);
      padding: 0 var(--wb-space-2) var(--wb-space-1); height: 0; overflow: hidden;
      transition: height var(--wb-dur); }
    :host([state="thinking"]) .status,
    :host([state="streaming"]) .status { height: 18px; }
    .status .dots { color: var(--wb-brand); vertical-align: middle; margin-left: var(--wb-space-1); }
  `;

  /** Programmatic value. */
  get value() {
    return this.shadowRoot.querySelector("textarea")?.value || "";
  }
  set value(v) {
    const ta = this.shadowRoot.querySelector("textarea");
    if (ta) ta.value = v;
  }

  get busy() {
    return this.attr("state", "idle") !== "idle" || this.boolAttr("disabled");
  }

  _submit() {
    if (this.busy) return;
    const ta = this.shadowRoot.querySelector("textarea");
    const text = (ta?.value || "").trim();
    if (!text) return;
    this.dispatchEvent(
      new CustomEvent("wb-intent", {
        bubbles: true,
        composed: true,
        detail: { action: "send", text },
      }),
    );
    if (ta) ta.value = "";
  }

  connectedCallback() {
    super.connectedCallback();
    if (this._wired) return;
    this._wired = true;
    this.shadowRoot.addEventListener("click", (e) => {
      if (e.target.closest(".send")) this._submit();
    });
    this.shadowRoot.addEventListener("keydown", (e) => {
      // Enter submits; Shift+Enter inserts a newline.
      if (e.key === "Enter" && !e.shiftKey && e.target.tagName === "TEXTAREA") {
        e.preventDefault();
        this._submit();
      }
    });
  }

  render() {
    const ph = this.attr("placeholder", "Message the agent…");
    const state = this.attr("state", "idle");
    const label = state === "thinking" ? "Thinking" : state === "streaming" ? "Streaming" : "";
    const dots = `<span class="dots"><i></i><i></i><i></i></span>`;
    const sendIcon = this.busy
      ? dots
      : `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M22 2 11 13M22 2l-7 20-4-9-9-4 20-7z"/></svg>`;
    return `
      <div class="status">${label}${label ? dots : ""}</div>
      <div class="composer">
        <textarea part="input" rows="1" placeholder="${ph.replace(/"/g, "&quot;")}" ${this.busy ? "tabindex=-1" : ""}></textarea>
        <button class="send" part="send" aria-label="Send" ${this.busy ? "disabled" : ""}>${sendIcon}</button>
      </div>`;
  }
}

define("wb-composer", WbComposer);
