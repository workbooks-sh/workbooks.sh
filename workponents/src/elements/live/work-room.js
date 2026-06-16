// <work-room> — the realtime container. Joins a topic and slots its content.
//
// The reinvention: a room is a ROUTING CONFIG, not a backend. Set `topic` and the
// room opens a presence/pubsub channel over the Host seam (the BEAM over RCP when
// a runtime is reachable, a BroadcastChannel mock standalone) — no service to
// provision. Child live elements (<work-presence>, <work-cursors>, <work-live-value>)
// find their channel through the room, so one connection backs the whole subtree.
//
// Attributes:
//   topic   (required)  the channel topic, e.g. "room:design-review"
//   name                this client's display name (presence meta)
//   color               this client's color (presence meta; auto if unset)
//   manual              don't auto-join on connect (call .join())
// Reflected state attr:  state = "idle|joining|joined|error|closed"
// Events:
//   work-room-state  { state, topic, mock }   — on every connection-state change
// Property:  el.channel  → the live Channel (for child elements / scripting)
import { WbElement, html, css, define } from "../../core/element.js";
import { openChannel, clientId, colorFor } from "./channel.js";

export class WorkRoom extends WbElement {
  static props = ["topic", "name", "color", "state"];

  static properties = {
    ...WbElement.properties,
    _conn: { state: true },   // connection label, drives the Lit template
    _mock: { state: true },   // mock | rcp badge
  };

  static styles = css`
    :host { display: block; font-family: var(--work-font); color: var(--work-fg); }
    .room {
      border: 1px solid var(--work-border); border-radius: var(--work-radius);
      background: var(--work-surface); box-shadow: var(--work-shadow-sm); overflow: hidden;
    }
    .head {
      display: flex; align-items: center; gap: var(--work-space-3);
      padding: var(--work-space-3) var(--work-space-4);
      border-bottom: 1px solid var(--work-border); background: var(--work-surface-soft);
    }
    .topic { font: 600 var(--work-text-sm) var(--work-font-mono); color: var(--work-fg);
      overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .spacer { flex: 1; }
    .conn { display: inline-flex; align-items: center; gap: var(--work-space-2);
      font: 600 11px var(--work-font-mono); letter-spacing: .04em; text-transform: uppercase;
      color: var(--work-fg-muted); }
    .dot { width: 8px; height: 8px; border-radius: 50%; background: var(--work-fg-subtle); flex: none; }
    :host([state="joined"]) .dot { background: var(--work-ok); box-shadow: 0 0 0 3px var(--work-brand-soft); }
    :host([state="joining"]) .dot { background: var(--work-warn); animation: pulse 1s var(--work-ease) infinite; }
    :host([state="error"]) .dot,
    :host([state="closed"]) .dot { background: var(--work-err); }
    @keyframes pulse { 0%,100% { opacity: 1 } 50% { opacity: .35 } }
    .badge { font: 600 10px var(--work-font-mono); letter-spacing: .08em; text-transform: uppercase;
      padding: var(--work-space-2px) var(--work-space-7px); border-radius: var(--work-radius-pill); border: 1px solid var(--work-border);
      color: var(--work-fg-subtle); background: var(--work-bg); }
    .body { padding: var(--work-space-4); position: relative; }
    ::slotted([slot="head"]) { display: contents; }
  `;

  constructor() {
    super();
    this._conn = "offline";
    this._mock = true;
  }

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
    this.dispatchEvent(new CustomEvent("work-room-ready", { bubbles: false, detail: { channel: this._ch } }));
  }

  _reflect(state) {
    this.setAttribute("state", state);
    this.dispatchEvent(new CustomEvent("work-room-state", {
      bubbles: true, composed: true,
      detail: { state, topic: this.attr("topic"), mock: !!this._ch?.isMock },
    }));
    const label = { idle: "offline", joining: "connecting", joined: "live", error: "offline", closed: "left" }[state] || state;
    this._conn = label;
    this._mock = !!this._ch?.isMock;
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
    super.disconnectedCallback();
    this._unsub?.();
    // pooled channel is shared; don't close it here (other rooms/tabs may use it)
  }

  render() {
    return html`
      <div class="room" part="room">
        <div class="head" part="head">
          <span class="topic">${this.attr("topic") || "—"}</span>
          <slot name="head"></slot>
          <span class="spacer"></span>
          <span class="badge">${this._mock ? "mock" : "rcp"}</span>
          <span class="conn"><span class="dot"></span><span class="txt">${this._conn}</span></span>
        </div>
        <div class="body" part="body"><slot></slot></div>
      </div>`;
  }
}

define("work-room", WorkRoom);
