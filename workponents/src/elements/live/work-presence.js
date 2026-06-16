// <work-presence> — who's here, live. Renders the channel's presence set.
//
// Binds to the room's Channel (own `topic` attr, else the nearest <work-room>) and
// re-renders on every presence diff — joins/leaves/metadata updates flow straight
// off Phoenix Presence (real) or the BroadcastChannel mock (standalone), same
// shape either way. Themed entirely from --work-*; the per-client color is the only
// non-token value and it comes from presence metadata.
//
// Attributes:
//   topic              bind to a topic directly (else inherits the parent room)
//   variant = "avatars" | "list" | "count"   how to render the set
//   max                avatars: max shown before "+N" (default 5)
//   self="hide"        omit this client from the rendered set
// Events:
//   work-presence-change { list, count, joins, leaves }   — on every presence diff
// Usage:  <work-presence></work-presence>  ·  <work-presence variant="list"></work-presence>
import { WbElement, html, css, define } from "../../core/element.js";
import { defineVariants, variantAttrs } from "../../core/variants.js";
import { clientId, colorFor } from "./channel.js";
import { resolveChannel } from "./resolve.js";

const VARIANTS = defineVariants({
  variant: { options: ["avatars", "list", "count"], default: "avatars" },
});

export class WorkPresence extends WbElement {
  static variants = VARIANTS;
  static props = [...variantAttrs(VARIANTS), "topic", "max", "self"];

  static styles = css`
    :host { display: inline-block; font-family: var(--work-font); color: var(--work-fg); }
    .stack { display: inline-flex; align-items: center; }
    .ava {
      width: 30px; height: 30px; border-radius: 50%; flex: none;
      display: inline-grid; place-items: center; overflow: hidden;
      font: 700 11px var(--work-font-mono); color: var(--work-on-scrim);
      border: 2px solid var(--work-surface); margin-left: -8px;
      box-shadow: var(--work-shadow-sm); transition: transform var(--work-dur) var(--work-ease);
    }
    .ava:first-child { margin-left: 0; }
    .ava:hover { transform: translateY(-2px); z-index: 2; }
    .ava img { width: 100%; height: 100%; object-fit: cover; }
    .ava.more { background: var(--work-surface-soft); color: var(--work-fg-muted); }
    .ava.me { box-shadow: 0 0 0 2px var(--work-ring), var(--work-shadow-sm); }

    .count { display: inline-flex; align-items: center; gap: var(--work-space-2);
      font: 600 var(--work-text-sm) var(--work-font); color: var(--work-fg-muted); }
    .count .pip { width: 8px; height: 8px; border-radius: 50%; background: var(--work-ok);
      box-shadow: 0 0 0 3px var(--work-brand-soft); flex: none; }
    .count b { color: var(--work-fg); font-variant-numeric: tabular-nums; }

    .list { display: flex; flex-direction: column; gap: var(--work-space-1); }
    .row { display: flex; align-items: center; gap: var(--work-space-3);
      padding: var(--work-space-2) var(--work-space-2); border-radius: var(--work-radius-sm); }
    .row:hover { background: var(--work-surface-soft); }
    .row .ava { margin: 0; width: 26px; height: 26px; }
    .row .nm { font-size: var(--work-text-sm); font-weight: 600; }
    .row .tag { margin-left: auto; font: 600 10px var(--work-font-mono); letter-spacing: .08em;
      text-transform: uppercase; color: var(--work-fg-subtle); }
    .empty { font-size: var(--work-text-sm); color: var(--work-fg-subtle); }
  `;

  connectedCallback() {
    super.connectedCallback();
    this._me = clientId();
    this._bind();
  }
  disconnectedCallback() { super.disconnectedCallback(); this._unsub?.(); }

  _bind() {
    this._ch = resolveChannel(this);
    if (!this._ch) {
      // room may not have opened its channel yet; retry next frame, then on state
      requestAnimationFrame(() => { if (!this._ch) { this._bind(); this.requestUpdate(); } });
      this.addEventListener("__wb_retry__", () => this._bind(), { once: true });
      return;
    }
    this._unsub?.();
    this._unsub = this._ch.on("presence", (detail) => this._onPresence(detail));
    this.requestUpdate();
    if (this._ch.state === "joined") this._emit({ list: this._ch.presence(), joins: [], leaves: [] });
  }

  _onPresence(detail) {
    this.requestUpdate();
    this._emit(detail);
  }

  _emit({ list, joins, leaves }) {
    this.dispatchEvent(new CustomEvent("work-presence-change", {
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

  _nameOf(p) { return p.meta?.name || ("Guest " + p.id.slice(-4).toUpperCase()); }

  _avatar(p, extraClass = "") {
    const name = this._nameOf(p);
    const color = p.meta?.color || colorFor(p.id);
    const isMe = p.id === this._me;
    const init = name.split(/[\s._-]+/).filter(Boolean).slice(0, 2).map((w) => w[0]).join("").toUpperCase() || name[0]?.toUpperCase() || "?";
    const inner = p.meta?.avatar ? html`<img src=${p.meta.avatar} alt="" />` : init;
    return html`<span class=${"ava" + (isMe ? " me" : "") + (extraClass ? " " + extraClass : "")}
      style=${`background:${color}`} title=${name + (isMe ? " (you)" : "")}>${inner}</span>`;
  }

  render() {
    const v = this.attr("variant", "avatars");
    const members = this._members();
    if (v === "count") {
      return html`<span class="count"><span class="pip"></span><b>${members.length}</b> here</span>`;
    }
    if (v === "list") {
      if (!members.length) return html`<div class="list"><span class="empty">No one here yet.</span></div>`;
      return html`<div class="list">${members.map((p) => html`
        <div class="row">${this._avatar(p)}<span class="nm">${this._nameOf(p)}</span>${
          p.id === this._me ? html`<span class="tag">you</span>` : ""}</div>`)}</div>`;
    }
    // avatars (default)
    const max = parseInt(this.attr("max", "5"), 10);
    const shown = members.slice(0, max);
    const extra = members.length - shown.length;
    return html`<span class="stack">${shown.map((p) => this._avatar(p))}${
      extra > 0 ? html`<span class="ava more" title=${extra + " more"}>+${extra}</span>` : ""
    }</span>`;
  }
}

define("work-presence", WorkPresence);
