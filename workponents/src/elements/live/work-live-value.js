// <work-live-value> — a single shared value that syncs across every client.
//
// The reinvention made concrete: shared state is just a published event on the
// room's channel (no CRDT, no provisioned KV) — set it here and it lands on every
// other client instantly, off the BEAM over RCP when a runtime is reachable, off
// the BroadcastChannel mock standalone. Last-write-wins with a logical clock
// (lamport-ish: max(seen)+1, ties broken by client id), which is the right floor;
// a workbook that needs convergence opts CRDT in per the live brief.
//
// It renders an inline control bound to the value and reflects remote changes
// live. Three shapes cover the common cases: counter, toggle, text.
//
// Attributes:
//   topic              bind directly (else inherits the nearest <work-room>)
//   name               the value's key on the channel (default "value")
//   variant = "counter" | "toggle" | "text"
//   label              caption shown beside the control
//   value              initial/local value (number|bool-ish|string per variant)
// Events:
//   work-value-change { name, value, from, local }   — on any change (local or remote)
// Property:  el.value  (get/set; setting publishes)
import { WbElement, html, css, define } from "../../core/element.js";
import { ref, createRef } from "lit/directives/ref.js";
import { defineVariants, variantAttrs } from "../../core/variants.js";
import { clientId } from "./channel.js";
import { resolveChannel } from "./resolve.js";

const VARIANTS = defineVariants({
  variant: { options: ["counter", "toggle", "text"], default: "counter" },
});

export class WorkLiveValue extends WbElement {
  static variants = VARIANTS;
  static props = [...variantAttrs(VARIANTS), "topic", "name", "label", "value"];

  static properties = {
    ...WbElement.properties,
    _v: { state: true },   // the live value drives the Lit control
  };

  static styles = css`
    :host { display: inline-block; font-family: var(--work-font); color: var(--work-fg); }
    .box { display: inline-flex; align-items: center; gap: var(--work-space-3);
      border: 1px solid var(--work-border); border-radius: var(--work-radius);
      background: var(--work-surface); padding: var(--work-space-2) var(--work-space-3); }
    .label { font: 600 var(--work-text-sm) var(--work-font); color: var(--work-fg-muted); }
    .val { font: 700 var(--work-text-lg) var(--work-font-mono); color: var(--work-fg);
      min-width: 2ch; text-align: center; font-variant-numeric: tabular-nums;
      transition: color var(--work-dur) var(--work-ease); }
    .flash { animation: flash .5s var(--work-ease); }
    @keyframes flash { from { color: var(--work-brand) } to { color: var(--work-fg) } }
    button.step {
      width: 28px; height: 28px; flex: none; border-radius: var(--work-radius-sm);
      border: 1.5px solid var(--work-border-strong); background: var(--work-surface); color: var(--work-fg);
      font: 700 16px var(--work-font-mono); line-height: 1; cursor: pointer;
      transition: background var(--work-dur) var(--work-ease), transform var(--work-dur) var(--work-ease); }
    button.step:hover { background: var(--work-surface-soft); }
    button.step:active { transform: scale(.92); }

    .switch { position: relative; width: 44px; height: 26px; flex: none;
      border-radius: var(--work-radius-pill); background: var(--work-surface-soft);
      border: 1.5px solid var(--work-border-strong); cursor: pointer; padding: 0;
      transition: background var(--work-dur) var(--work-ease); }
    .switch[aria-checked="true"] { background: var(--work-brand); border-color: var(--work-brand); }
    .switch .knob { position: absolute; top: 1px; left: 1px; width: 20px; height: 20px;
      border-radius: 50%; background: var(--work-surface); box-shadow: var(--work-shadow-sm);
      transition: transform var(--work-dur) var(--work-ease); }
    .switch[aria-checked="true"] .knob { transform: translateX(18px); }

    input.text { font: var(--work-text) var(--work-font); color: var(--work-fg);
      background: var(--work-bg); border: 1.5px solid var(--work-border); border-radius: var(--work-radius-sm);
      padding: var(--work-space-2) var(--work-space-3); min-width: 16ch; }
    input.text:focus-visible { outline: none; box-shadow: 0 0 0 3px var(--work-ring); border-color: var(--work-brand); }
  `;

  constructor() {
    super();
    this._valRef = createRef();
  }

  get key() { return this.attr("name", "value"); }

  get value() { return this._v; }
  set value(v) { this._apply(v, true); }

  connectedCallback() {
    super.connectedCallback();
    this._me = clientId();
    this._clock = 0;
    this._v = this._coerce(this.attr("value"));
    this._bind();
  }
  disconnectedCallback() { super.disconnectedCallback(); this._unsub?.(); this._reqUnsub?.(); }

  _coerce(raw) {
    const v = this.attr("variant", "counter");
    if (v === "counter") return Number(raw ?? 0) || 0;
    if (v === "toggle") return raw === "true" || raw === true || raw === "" ? true : false;
    return raw == null ? "" : String(raw);
  }

  _bind() {
    this._ch = resolveChannel(this);
    if (!this._ch) { requestAnimationFrame(() => { if (!this._ch) { this._bind(); this.requestUpdate(); } }); return; }
    this._unsub?.();
    // a single event channel namespaced by key
    this._unsub = this._ch.on("value:" + this.key, ({ payload, from }) => this._remote(payload, from));
    // ask the room for the current value once joined (a peer answers with its state)
    this._ch.publish("value:req", { key: this.key, from: this._me });
    this._reqUnsub = this._ch.on("value:req", ({ payload }) => {
      if (payload?.key === this.key) this._publish(); // answer with our state
    });
    this.requestUpdate();
  }

  _remote(payload, from) {
    if (!payload || payload.clock == null) return;
    // last-write-wins by logical clock, ties → higher client id
    if (payload.clock < this._clock) return;
    if (payload.clock === this._clock && from <= this._me) return;
    this._clock = payload.clock;
    this._apply(payload.value, false, from);
  }

  _apply(v, local, from) {
    this._v = v;
    if (local) { this._clock += 1; this._publish(); }
    this._flash();
    this.dispatchEvent(new CustomEvent("work-value-change", {
      bubbles: true, composed: true,
      detail: { name: this.key, value: this._v, from: local ? this._me : (from || "remote"), local: !!local },
    }));
  }

  _publish() { this._ch?.publish("value:" + this.key, { value: this._v, clock: this._clock, from: this._me }); }

  _flash() {
    // run after the reactive update paints the new value
    this.updateComplete.then(() => {
      const el = this._valRef.value;
      if (el) { el.classList.remove("flash"); void el.offsetWidth; el.classList.add("flash"); }
    });
  }

  render() {
    const v = this.attr("variant", "counter");
    const label = this.attr("label");
    const cap = label ? html`<span class="label">${label}</span>` : "";
    if (v === "toggle") {
      return html`<div class="box">${cap}<button class="switch" role="switch"
        aria-checked=${String(!!this._v)} part="switch"
        @click=${() => this._apply(!this._v, true)}><span class="knob"></span></button></div>`;
    }
    if (v === "text") {
      return html`<div class="box">${cap}<input class="text" part="input"
        .value=${String(this._v ?? "")} placeholder="type — syncs live"
        @input=${(e) => this._apply(e.target.value, true)} /></div>`;
    }
    return html`<div class="box">${cap}<button class="step dec" part="dec" aria-label="decrement"
      @click=${() => this._apply(Number(this._v) - 1, true)}>−</button><span class="val" part="value"
      ${ref(this._valRef)}>${Number(this._v) || 0}</span><button class="step inc" part="inc"
      aria-label="increment" @click=${() => this._apply(Number(this._v) + 1, true)}>+</button></div>`;
  }
}

define("work-live-value", WorkLiveValue);
