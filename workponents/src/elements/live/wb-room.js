// <wb-room> — the realtime container. Joins a topic and slots its content.
//
// The reinvention: a room is a ROUTING CONFIG, not a backend. Set `topic` and the
// room opens a presence/pubsub channel over the Host seam (the BEAM over RCP when
// a runtime is reachable, a BroadcastChannel mock standalone) — no service to
// provision. Child live elements (<wb-presence>, <wb-cursors>, <wb-live-value>)
// find their channel through the room, so one connection backs the whole subtree.
//
// Attributes:
//   topic   (required)  the channel topic, e.g. "room:design-review"
//   name                this client's display name (presence meta)
//   color               this client's color (presence meta; auto if unset)
//   manual              don't auto-join on connect (call .join())
// Reflected state attr:  state = "idle|joining|joined|error|closed"
// Events:
//   wb-room-state  { state, topic, mock }   — on every connection-state change
// Property:  el.channel  → the live Channel (for child elements / scripting)
import { WbElement, define } from "../../core/element.js";
import { openChannel, clientId, colorFor } from "./channel.js";

export class WbRoom extends WbElement {
  static props = ["topic", "name", "color", "state"];

  static styles = `
    :host { display: block; font-family: var(--wb-font); color: var(--wb-fg); }
    .room {
      border: 1px solid var(--wb-border); border-radius: var(--wb-radius);
      background: var(--wb-surface); box-shadow: var(--wb-shadow-sm); overflow: hidden;
    }
    .head {
      display: flex; align-items: center; gap: var(--wb-space-3);
      padding: var(--wb-space-3) var(--wb-space-4);
      border-bottom: 1px solid var(--wb-border); background: var(--wb-surface-soft);
    }
    .topic { font: 600 var(--wb-text-sm) var(--wb-font-mono); color: var(--wb-fg);
      overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .spacer { flex: 1; }
    .conn { display: inline-flex; align-items: center; gap: var(--wb-space-2);
      font: 600 11px var(--wb-font-mono); letter-spacing: .04em; text-transform: uppercase;
      color: var(--wb-fg-muted); }
    .dot { width: 8px; height: 8px; border-radius: 50%; background: var(--wb-fg-subtle); flex: none; }
    :host([state="joined"]) .dot { background: var(--wb-ok); box-shadow: 0 0 0 3px var(--wb-brand-soft); }
    :host([state="joining"]) .dot { background: var(--wb-warn); animation: pulse 1s var(--wb-ease) infinite; }
    :host([state="error"]) .dot,
    :host([state="closed"]) .dot { background: var(--wb-err); }
    @keyframes pulse { 0%,100% { opacity: 1 } 50% { opacity: .35 } }
    .badge { font: 600 10px var(--wb-font-mono); letter-spacing: .08em; text-transform: uppercase;
      padding: 2px 7px; border-radius: var(--wb-radius-pill); border: 1px solid var(--wb-border);
      color: var(--wb-fg-subtle); background: var(--wb-bg); }
    .body { padding: var(--wb-space-4); position: relative; }
    ::slotted([slot="head"]) { display: contents; }
  `;

  get channel() { return this._ch || null; }

  /** Open the channel + announce presence. Idempotent. */
  join() {
    if (this._ch) return;
    const topic = this.attr("topic");
    if (!topic) { this.setAttribute("state", "error"); return; }
    const meta = {
      name: this.attr("name") || this._defaultName(),
      color: this.attr("color") || colorFor(clientId()),
    };
    this._ch = openChannel(topic, { meta });
    this._unsub = this._ch.on("state", ({ state }) => this._reflect(state));
    this._reflect(this._ch.state);
    this._ch.join();
    // make the channel discoverable by descendants synchronously
    this.dispatchEvent(new CustomEvent("wb-room-ready", { bubbles: false, detail: { channel: this._ch } }));
  }

  _reflect(state) {
    this.setAttribute("state", state);
    this.dispatchEvent(new CustomEvent("wb-room-state", {
      bubbles: true, composed: true,
      detail: { state, topic: this.attr("topic"), mock: !!this._ch?.isMock },
    }));
    this._renderHead();
  }

  _defaultName() {
    const id = clientId();
    return "Guest " + id.slice(-4).toUpperCase();
  }

  connectedCallback() {
    super.connectedCallback();
    if (!this.boolAttr("manual")) this.join();
  }

  disconnectedCallback() {
    this._unsub?.();
    // pooled channel is shared; don't close it here (other rooms/tabs may use it)
  }

  _renderHead() {
    const c = this.shadowRoot.querySelector(".conn");
    if (!c) return;
    const st = this.attr("state", "idle");
    const label = { idle: "offline", joining: "connecting", joined: "live", error: "offline", closed: "left" }[st] || st;
    c.querySelector(".txt").textContent = label;
    const badge = this.shadowRoot.querySelector(".badge");
    if (badge) badge.textContent = this._ch?.isMock ? "mock" : "rcp";
  }

  render() {
    return `
      <div class="room" part="room">
        <div class="head" part="head">
          <span class="topic">${this.attr("topic") || "—"}</span>
          <slot name="head"></slot>
          <span class="spacer"></span>
          <span class="badge"></span>
          <span class="conn"><span class="dot"></span><span class="txt">offline</span></span>
        </div>
        <div class="body" part="body"><slot></slot></div>
      </div>`;
  }

  update() {
    super.update();
    this._renderHead();
  }
}

define("wb-room", WbRoom);
