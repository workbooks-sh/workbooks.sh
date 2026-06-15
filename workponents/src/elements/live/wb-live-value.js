// <wb-live-value> — a single shared value that syncs across every client.
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
//   topic              bind directly (else inherits the nearest <wb-room>)
//   name               the value's key on the channel (default "value")
//   variant = "counter" | "toggle" | "text"
//   label              caption shown beside the control
//   value              initial/local value (number|bool-ish|string per variant)
// Events:
//   wb-value-change { name, value, from, local }   — on any change (local or remote)
// Property:  el.value  (get/set; setting publishes)
import { WbElement, define } from "../../core/element.js";
import { defineVariants, variantAttrs } from "../../core/variants.js";
import { clientId } from "./channel.js";
import { resolveChannel } from "./resolve.js";

const VARIANTS = defineVariants({
  variant: { options: ["counter", "toggle", "text"], default: "counter" },
});

export class WbLiveValue extends WbElement {
  static variants = VARIANTS;
  static props = [...variantAttrs(VARIANTS), "topic", "name", "label", "value"];

  static styles = `
    :host { display: inline-block; font-family: var(--wb-font); color: var(--wb-fg); }
    .box { display: inline-flex; align-items: center; gap: var(--wb-space-3);
      border: 1px solid var(--wb-border); border-radius: var(--wb-radius);
      background: var(--wb-surface); padding: var(--wb-space-2) var(--wb-space-3); }
    .label { font: 600 var(--wb-text-sm) var(--wb-font); color: var(--wb-fg-muted); }
    .val { font: 700 var(--wb-text-lg) var(--wb-font-mono); color: var(--wb-fg);
      min-width: 2ch; text-align: center; font-variant-numeric: tabular-nums;
      transition: color var(--wb-dur) var(--wb-ease); }
    .flash { animation: flash .5s var(--wb-ease); }
    @keyframes flash { from { color: var(--wb-brand) } to { color: var(--wb-fg) } }
    button.step {
      width: 28px; height: 28px; flex: none; border-radius: var(--wb-radius-sm);
      border: 1.5px solid var(--wb-border-strong); background: var(--wb-surface); color: var(--wb-fg);
      font: 700 16px var(--wb-font-mono); line-height: 1; cursor: pointer;
      transition: background var(--wb-dur) var(--wb-ease), transform var(--wb-dur) var(--wb-ease); }
    button.step:hover { background: var(--wb-surface-soft); }
    button.step:active { transform: scale(.92); }

    .switch { position: relative; width: 44px; height: 26px; flex: none;
      border-radius: var(--wb-radius-pill); background: var(--wb-surface-soft);
      border: 1.5px solid var(--wb-border-strong); cursor: pointer; padding: 0;
      transition: background var(--wb-dur) var(--wb-ease); }
    .switch[aria-checked="true"] { background: var(--wb-brand); border-color: var(--wb-brand); }
    .switch .knob { position: absolute; top: 1px; left: 1px; width: 20px; height: 20px;
      border-radius: 50%; background: var(--wb-surface); box-shadow: var(--wb-shadow-sm);
      transition: transform var(--wb-dur) var(--wb-ease); }
    .switch[aria-checked="true"] .knob { transform: translateX(18px); }

    input.text { font: var(--wb-text) var(--wb-font); color: var(--wb-fg);
      background: var(--wb-bg); border: 1.5px solid var(--wb-border); border-radius: var(--wb-radius-sm);
      padding: var(--wb-space-2) var(--wb-space-3); min-width: 16ch; }
    input.text:focus-visible { outline: none; box-shadow: 0 0 0 3px var(--wb-ring); border-color: var(--wb-brand); }
  `;

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
  disconnectedCallback() { this._unsub?.(); }

  _coerce(raw) {
    const v = this.attr("variant", "counter");
    if (v === "counter") return Number(raw ?? 0) || 0;
    if (v === "toggle") return raw === "true" || raw === true || raw === "" ? true : false;
    return raw == null ? "" : String(raw);
  }

  _bind() {
    this._ch = resolveChannel(this);
    if (!this._ch) { requestAnimationFrame(() => { if (!this._ch) { this._bind(); this.update(); } }); return; }
    this._unsub?.();
    // a single event channel namespaced by key
    this._unsub = this._ch.on("value:" + this.key, ({ payload, from }) => this._remote(payload, from));
    // ask the room for the current value once joined (a peer answers with its state)
    this._ch.publish("value:req", { key: this.key, from: this._me });
    this._reqUnsub = this._ch.on("value:req", ({ payload }) => {
      if (payload?.key === this.key) this._publish(); // answer with our state
    });
    this.update();
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
    this.update();
    this.dispatchEvent(new CustomEvent("wb-value-change", {
      bubbles: true, composed: true,
      detail: { name: this.key, value: this._v, from: local ? this._me : (from || "remote"), local: !!local },
    }));
  }

  _publish() { this._ch?.publish("value:" + this.key, { value: this._v, clock: this._clock, from: this._me }); }

  _flash() {
    const el = this.shadowRoot.querySelector(".val");
    if (el) { el.classList.remove("flash"); void el.offsetWidth; el.classList.add("flash"); }
  }

  update() {
    super.update();
    const v = this.attr("variant", "counter");
    const root = this.shadowRoot;
    if (v === "counter") {
      root.querySelector(".dec")?.addEventListener("click", () => this._apply(Number(this._v) - 1, true));
      root.querySelector(".inc")?.addEventListener("click", () => this._apply(Number(this._v) + 1, true));
    } else if (v === "toggle") {
      root.querySelector(".switch")?.addEventListener("click", () => this._apply(!this._v, true));
    } else {
      const inp = root.querySelector("input.text");
      if (inp) inp.addEventListener("input", (e) => this._apply(e.target.value, true));
    }
  }

  render() {
    const v = this.attr("variant", "counter");
    const label = this.attr("label");
    const cap = label ? `<span class="label">${label}</span>` : "";
    if (v === "toggle") {
      return `<div class="box">${cap}<button class="switch" role="switch" aria-checked="${!!this._v}" part="switch"><span class="knob"></span></button></div>`;
    }
    if (v === "text") {
      return `<div class="box">${cap}<input class="text" part="input" value="${String(this._v ?? "").replace(/"/g, "&quot;")}" placeholder="type — syncs live" /></div>`;
    }
    return `<div class="box">${cap}<button class="step dec" part="dec" aria-label="decrement">−</button><span class="val" part="value">${Number(this._v) || 0}</span><button class="step inc" part="inc" aria-label="increment">+</button></div>`;
  }
}

define("wb-live-value", WbLiveValue);
