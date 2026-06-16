// <work-composer> — the conversation input. Emits an intent rather than wiring
// to a transport itself: on submit it dispatches a `work-intent` CustomEvent
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
//   <work-composer placeholder="Message the agent…"></work-composer>
//   composer.addEventListener("work-intent", (e) => { … e.detail.text … });
//   composer.setAttribute("state", "thinking");  // host flips it while busy
import { WbElement, html, css, define } from "../../core/element.js";
import { ref, createRef } from "lit/directives/ref.js";
import { defineVariants, variantAttrs } from "../../core/variants.js";

const VARIANTS = defineVariants({
  state: { options: ["idle", "thinking", "streaming"], default: "idle" },
});

export class WbComposer extends WbElement {
  static variants = VARIANTS;
  static props = [...variantAttrs(VARIANTS), "placeholder", "disabled"];

  _ta = createRef();

  static styles = css`
    :host { display: block; font-family: var(--work-font); color: var(--work-fg); }
    .composer {
      display: flex; align-items: flex-end; gap: var(--work-space-2);
      border: 1.5px solid var(--work-border-strong);
      border-radius: var(--work-radius-lg);
      background: var(--work-surface);
      padding: var(--work-space-2) var(--work-space-2) var(--work-space-2) var(--work-space-4);
      transition: border-color var(--work-dur) var(--work-ease), box-shadow var(--work-dur) var(--work-ease);
    }
    .composer:focus-within { border-color: var(--work-brand); box-shadow: 0 0 0 3px var(--work-ring); }
    textarea {
      flex: 1; resize: none; border: 0; outline: 0; background: none;
      font: var(--work-text)/1.5 var(--work-font); color: var(--work-fg);
      padding: var(--work-space-2) 0; max-height: 180px;
    }
    textarea::placeholder { color: var(--work-fg-subtle); }
    .send {
      display: inline-grid; place-items: center; width: 34px; height: 34px; flex: none;
      border: 0; border-radius: var(--work-radius); cursor: pointer;
      background: var(--work-brand); color: var(--work-on-brand);
      transition: filter var(--work-dur) var(--work-ease), opacity var(--work-dur) var(--work-ease);
    }
    .send:hover { filter: brightness(1.06); }
    .send:focus-visible { outline: none; box-shadow: 0 0 0 3px var(--work-ring); }
    .send svg { width: 16px; height: 16px; }

    /* busy states: lock input, show a live indicator in place of the icon */
    :host([state="thinking"]) textarea,
    :host([state="streaming"]) textarea,
    :host([disabled]) textarea { pointer-events: none; opacity: .6; }
    :host([state="thinking"]) .composer,
    :host([state="streaming"]) .composer { border-color: var(--work-brand); }

    .dots { display: inline-flex; gap: 3px; }
    .dots i { width: 5px; height: 5px; border-radius: 50%; background: currentColor;
      animation: wb-pulse 1s var(--work-ease) infinite; }
    .dots i:nth-child(2) { animation-delay: .15s; }
    .dots i:nth-child(3) { animation-delay: .3s; }
    @keyframes wb-pulse { 0%,80%,100% { opacity: .25; transform: scale(.8); } 40% { opacity: 1; transform: scale(1); } }

    .status { font: 600 11px var(--work-font-mono); letter-spacing: .06em;
      text-transform: uppercase; color: var(--work-fg-muted);
      padding: 0 var(--work-space-2) var(--work-space-1); height: 0; overflow: hidden;
      transition: height var(--work-dur); }
    :host([state="thinking"]) .status,
    :host([state="streaming"]) .status { height: 18px; }
    .status .dots { color: var(--work-brand); vertical-align: middle; margin-left: var(--work-space-1); }
  `;

  /** Programmatic value. */
  get value() {
    return this._ta.value?.value || "";
  }
  set value(v) {
    if (this._ta.value) this._ta.value.value = v;
  }

  get busy() {
    return this.attr("state", "idle") !== "idle" || this.boolAttr("disabled");
  }

  _submit() {
    if (this.busy) return;
    const ta = this._ta.value;
    const text = (ta?.value || "").trim();
    if (!text) return;
    this.dispatchEvent(
      new CustomEvent("work-intent", {
        bubbles: true,
        composed: true,
        detail: { action: "send", text },
      }),
    );
    if (ta) ta.value = "";
  }

  _onKeydown(e) {
    // Enter submits; Shift+Enter inserts a newline.
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      this._submit();
    }
  }

  render() {
    const ph = this.attr("placeholder", "Message the agent…");
    const state = this.attr("state", "idle");
    const label = state === "thinking" ? "Thinking" : state === "streaming" ? "Streaming" : "";
    const dots = html`<span class="dots"><i></i><i></i><i></i></span>`;
    const sendIcon = this.busy
      ? dots
      : html`<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M22 2 11 13M22 2l-7 20-4-9-9-4 20-7z"></path></svg>`;
    return html`
      <div class="status">${label}${label ? dots : ""}</div>
      <div class="composer">
        <textarea ${ref(this._ta)} part="input" rows="1" placeholder=${ph}
          tabindex=${this.busy ? "-1" : "0"} @keydown=${this._onKeydown}></textarea>
        <button class="send" part="send" aria-label="Send" ?disabled=${this.busy} @click=${this._submit}>${sendIcon}</button>
      </div>`;
  }
}

define("work-composer", WbComposer);
