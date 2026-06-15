// <wb-presence> — who's here, live. Renders the channel's presence set.
//
// Binds to the room's Channel (own `topic` attr, else the nearest <wb-room>) and
// re-renders on every presence diff — joins/leaves/metadata updates flow straight
// off Phoenix Presence (real) or the BroadcastChannel mock (standalone), same
// shape either way. Themed entirely from --wb-*; the per-client color is the only
// non-token value and it comes from presence metadata.
//
// Attributes:
//   topic              bind to a topic directly (else inherits the parent room)
//   variant = "avatars" | "list" | "count"   how to render the set
//   max                avatars: max shown before "+N" (default 5)
//   self="hide"        omit this client from the rendered set
// Events:
//   wb-presence-change { list, count, joins, leaves }   — on every presence diff
// Usage:  <wb-presence></wb-presence>  ·  <wb-presence variant="list"></wb-presence>
import { WbElement, define } from "../../core/element.js";
import { defineVariants, variantAttrs } from "../../core/variants.js";
import { clientId, colorFor } from "./channel.js";
import { resolveChannel } from "./resolve.js";

const VARIANTS = defineVariants({
  variant: { options: ["avatars", "list", "count"], default: "avatars" },
});

export class WbPresence extends WbElement {
  static variants = VARIANTS;
  static props = [...variantAttrs(VARIANTS), "topic", "max", "self"];

  static styles = `
    :host { display: inline-block; font-family: var(--wb-font); color: var(--wb-fg); }
    .stack { display: inline-flex; align-items: center; }
    .ava {
      width: 30px; height: 30px; border-radius: 50%; flex: none;
      display: inline-grid; place-items: center; overflow: hidden;
      font: 700 11px var(--wb-font-mono); color: #fff;
      border: 2px solid var(--wb-surface); margin-left: -8px;
      box-shadow: var(--wb-shadow-sm); transition: transform var(--wb-dur) var(--wb-ease);
    }
    .ava:first-child { margin-left: 0; }
    .ava:hover { transform: translateY(-2px); z-index: 2; }
    .ava img { width: 100%; height: 100%; object-fit: cover; }
    .ava.more { background: var(--wb-surface-soft); color: var(--wb-fg-muted); }
    .ava.me { box-shadow: 0 0 0 2px var(--wb-ring), var(--wb-shadow-sm); }

    .count { display: inline-flex; align-items: center; gap: var(--wb-space-2);
      font: 600 var(--wb-text-sm) var(--wb-font); color: var(--wb-fg-muted); }
    .count .pip { width: 8px; height: 8px; border-radius: 50%; background: var(--wb-ok);
      box-shadow: 0 0 0 3px var(--wb-brand-soft); flex: none; }
    .count b { color: var(--wb-fg); font-variant-numeric: tabular-nums; }

    .list { display: flex; flex-direction: column; gap: var(--wb-space-1); }
    .row { display: flex; align-items: center; gap: var(--wb-space-3);
      padding: var(--wb-space-2) var(--wb-space-2); border-radius: var(--wb-radius-sm); }
    .row:hover { background: var(--wb-surface-soft); }
    .row .ava { margin: 0; width: 26px; height: 26px; }
    .row .nm { font-size: var(--wb-text-sm); font-weight: 600; }
    .row .tag { margin-left: auto; font: 600 10px var(--wb-font-mono); letter-spacing: .08em;
      text-transform: uppercase; color: var(--wb-fg-subtle); }
    .empty { font-size: var(--wb-text-sm); color: var(--wb-fg-subtle); }
  `;

  connectedCallback() {
    super.connectedCallback();
    this._me = clientId();
    this._bind();
  }
  disconnectedCallback() { this._unsub?.(); }

  _bind() {
    this._ch = resolveChannel(this);
    if (!this._ch) {
      // room may not have opened its channel yet; retry next frame, then on state
      requestAnimationFrame(() => { if (!this._ch) { this._bind(); this.update(); } });
      this.addEventListener("__wb_retry__", () => this._bind(), { once: true });
      return;
    }
    this._unsub?.();
    this._unsub = this._ch.on("presence", (detail) => this._onPresence(detail));
    this.update();
    if (this._ch.state === "joined") this._emit({ list: this._ch.presence(), joins: [], leaves: [] });
  }

  _onPresence(detail) {
    this.update();
    this._emit(detail);
  }

  _emit({ list, joins, leaves }) {
    this.dispatchEvent(new CustomEvent("wb-presence-change", {
      bubbles: true, composed: true,
      detail: { list, count: list.length, joins: joins || [], leaves: leaves || [] },
    }));
  }

  _members() {
    let m = this._ch ? this._ch.presence() : [];
    if (this.attr("self") === "hide") m = m.filter((p) => p.id !== this._me);
    // stable order: self first, then by join time
    return m.sort((a, b) => (a.id === this._me ? -1 : b.id === this._me ? 1 : (a.online_at || 0) - (b.online_at || 0)));
  }

  _avatar(p, extraClass = "") {
    const name = p.meta?.name || ("Guest " + p.id.slice(-4).toUpperCase());
    const color = p.meta?.color || colorFor(p.id);
    const me = p.id === this._me ? " me" : "";
    const init = name.split(/[\s._-]+/).filter(Boolean).slice(0, 2).map((w) => w[0]).join("").toUpperCase() || name[0]?.toUpperCase() || "?";
    const img = p.meta?.avatar ? `<img src="${p.meta.avatar}" alt="" />` : init;
    return `<span class="ava${me} ${extraClass}" style="background:${color}" title="${name}${p.id === this._me ? " (you)" : ""}">${img}</span>`;
  }

  render() {
    const v = this.attr("variant", "avatars");
    const members = this._members();
    if (v === "count") {
      return `<span class="count"><span class="pip"></span><b>${members.length}</b> here</span>`;
    }
    if (v === "list") {
      if (!members.length) return `<div class="list"><span class="empty">No one here yet.</span></div>`;
      return `<div class="list">${members.map((p) => {
        const name = p.meta?.name || ("Guest " + p.id.slice(-4).toUpperCase());
        return `<div class="row">${this._avatar(p)}<span class="nm">${name}</span>${p.id === this._me ? `<span class="tag">you</span>` : ""}</div>`;
      }).join("")}</div>`;
    }
    // avatars (default)
    const max = parseInt(this.attr("max", "5"), 10);
    const shown = members.slice(0, max);
    const extra = members.length - shown.length;
    return `<span class="stack">${shown.map((p) => this._avatar(p)).join("")}${
      extra > 0 ? `<span class="ava more" title="${extra} more">+${extra}</span>` : ""
    }</span>`;
  }
}

define("wb-presence", WbPresence);
