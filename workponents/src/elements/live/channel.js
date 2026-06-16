// workponents · live domain — the channel seam (presence + pubsub).
//
// The reinvention: REALTIME IS A ROUTING CONFIG, not a provisioned backend.
// Presence/pubsub come FREE off the BEAM (Phoenix Presence + PubSub) over RCP
// through the Host socket seam — there is no separate realtime service to stand
// up, no Liveblocks/Pusher/Ably account, no schema. The elements bind to ONE
// small `Channel` abstraction layered on `this.host` (`host.socket(...)`). When a
// runtime is reachable it rides a real WebSocket to the BEAM; STANDALONE (no
// runtime) the SAME contract is served by a `BroadcastChannel` mock so the
// elements demo live — multiple tabs (or peers in one page) — with no backend.
//
// The elements never know which transport is live. That is the whole point: a
// `<live-room>` written against this seam works on a static page today and lights
// up against the runtime tomorrow with zero element changes — realtime as config.
//
// ────────────────────────────────────────────────────────────────────────────
// THE CONTRACT  (what every transport — real or mock — provides)
//
//   const ch = openChannel("room:design", { meta: { name, color } });
//   ch.join()                      → connects; resolves on first "joined"
//   ch.publish(event, payload)     → broadcast a message to the topic
//   ch.on(event, fn)               → subscribe to an event; returns unsubscribe
//   ch.track(meta)                 → set/update THIS client's presence metadata
//   ch.presence()                  → current presence list  [{ id, meta, online_at }]
//   ch.state                       → "idle" | "joining" | "joined" | "error" | "closed"
//   ch.leave() / ch.close()        → leave the topic / tear down
//
// Channel is an EventTarget. Lifecycle/data events (also reachable via `on`):
//   "state"     detail: { state }                       — connection state changed
//   "presence"  detail: { list, joins, leaves }         — presence set changed
//   "message"   detail: { event, payload, from, at }    — any published message
//   <event>     detail: { payload, from, at }           — a specific published event
//
// ────────────────────────────────────────────────────────────────────────────
// THE RUNTIME ENDPOINT SHAPE  (real transport — Phoenix over RCP)
//
//   host.socket("/live/" + topic, { onMessage })   → a WebSocket to the BEAM.
//   The runtime speaks a tiny Phoenix-flavored frame envelope (JSON):
//
//     client → server
//       { t: "join",     topic, ref, meta }            // enter + initial presence
//       { t: "track",    topic, ref, meta }            // update presence metadata
//       { t: "publish",  topic, ref, event, payload }  // broadcast to the topic
//       { t: "leave",    topic, ref }
//
//     server → client
//       { t: "joined",   topic, ref, presence }                    // ack + snapshot
//       { t: "presence", topic, joins, leaves, presence }          // Presence diff
//       { t: "message",  topic, event, payload, from, at }         // a broadcast
//       { t: "error",    topic, reason }
//
//   `presence` is the Phoenix Presence list mapped to [{ id, meta, online_at }].
//   `from` is the publisher's client id; `ref` correlates a client request to its
//   ack. A topic is any string ("room:<id>", "cursors:<doc>", "val:<key>"). This
//   maps 1:1 onto a Phoenix channel + Presence on the runtime — no new protocol.
//
// SUGGESTED CORE ADDITION (noted, not made): a first-class `host.channel(topic)`
// returning a `Channel` so every live element shares ONE connection per topic and
// the seam isn't re-derived per element. Until then we pool channels here, keyed
// by topic over the active Host.

import { getHost } from "../../core/host.js";

let _clientId = null;
/** A stable per-tab client id (presence identity for this browsing context). */
export function clientId() {
  if (_clientId) return _clientId;
  const k = "__wb_live_client__";
  try {
    _clientId = sessionStorage.getItem(k);
    if (!_clientId) {
      _clientId = "c_" + Math.random().toString(36).slice(2, 9) + Date.now().toString(36).slice(-3);
      sessionStorage.setItem(k, _clientId);
    }
  } catch {
    _clientId = "c_" + Math.random().toString(36).slice(2, 10);
  }
  return _clientId;
}

/** A deterministic, themeable color for a client id (presence dots/cursors). */
export function colorFor(id) {
  let h = 0;
  for (let i = 0; i < id.length; i++) h = (h * 31 + id.charCodeAt(i)) >>> 0;
  return `hsl(${h % 360} 68% 56%)`;
}

const now = () => Date.now();

/**
 * A presence/pubsub channel on a topic. Transport-agnostic: backed by a real
 * Host WebSocket when a runtime is reachable, else a same-machine BroadcastChannel
 * mock. Identical API + events either way.
 */
export class Channel extends EventTarget {
  /** @param {string} topic  @param {{ host?, meta?, mock?: boolean }} [opts] */
  constructor(topic, opts = {}) {
    super();
    this.topic = topic;
    this._host = opts.host || getHost();
    this._meta = opts.meta || {};
    this._id = clientId();
    this._mock = opts.mock != null ? opts.mock : !this._host.available?.("live");
    this._state = "idle";
    this._presence = new Map(); // id -> { id, meta, online_at }
    this._handlers = new Map(); // event -> Set<fn>
    this._ref = 0;
    this._transport = null;
  }

  get id() { return this._id; }
  get state() { return this._state; }
  get isMock() { return this._mock; }

  _setState(s) {
    if (this._state === s) return;
    this._state = s;
    this.dispatchEvent(new CustomEvent("state", { detail: { state: s } }));
  }

  /** Connect + announce presence. Resolves once joined. */
  join() {
    if (this._state === "joined" || this._state === "joining") return this._joinPromise || Promise.resolve();
    this._setState("joining");
    this._transport = this._mock ? new MockTransport(this) : new SocketTransport(this);
    this._joinPromise = new Promise((resolve) => { this._onJoined = resolve; });
    this._transport.start();
    return this._joinPromise;
  }

  /** Broadcast an event to everyone on the topic (self included by default). */
  publish(event, payload = {}) {
    const frame = { event, payload, from: this._id, at: now() };
    this._transport?.publish(frame);
    return frame;
  }

  /** Set/update THIS client's presence metadata; broadcast a presence diff. */
  track(meta = {}) {
    this._meta = { ...this._meta, ...meta };
    this._transport?.track(this._meta);
  }

  /** Subscribe to a published event (or "presence"/"state"/"message"). */
  on(event, fn) {
    if (event === "presence" || event === "state" || event === "message") {
      const h = (e) => fn(e.detail);
      this.addEventListener(event, h);
      return () => this.removeEventListener(event, h);
    }
    let set = this._handlers.get(event);
    if (!set) this._handlers.set(event, (set = new Set()));
    set.add(fn);
    return () => set.delete(fn);
  }

  /** Current presence list. */
  presence() {
    return [...this._presence.values()];
  }

  leave() {
    this._transport?.leave();
    this.close();
  }

  close() {
    this._transport?.close();
    this._transport = null;
    this._presence.clear();
    this._setState("closed");
  }

  // ── transport → channel callbacks (used by both transports) ──────────────
  _joined(presence) {
    this._ingestPresence(presence, true);
    this._setState("joined");
    this._onJoined?.();
  }

  _ingestPresence(list, replace = false) {
    const before = new Set(this._presence.keys());
    if (replace) this._presence.clear();
    for (const p of list || []) this._presence.set(p.id, p);
    const after = new Set(this._presence.keys());
    const joins = [...after].filter((x) => !before.has(x)).map((id) => this._presence.get(id));
    const leaves = [...before].filter((x) => !after.has(x)).map((id) => ({ id }));
    this.dispatchEvent(new CustomEvent("presence", { detail: { list: this.presence(), joins, leaves } }));
  }

  _presenceDiff({ joins = [], leaves = [] }) {
    for (const p of joins) this._presence.set(p.id, p);
    for (const l of leaves) this._presence.delete(l.id || l);
    this.dispatchEvent(new CustomEvent("presence", { detail: { list: this.presence(), joins, leaves } }));
  }

  _deliver({ event, payload, from, at }) {
    this.dispatchEvent(new CustomEvent("message", { detail: { event, payload, from, at } }));
    const set = this._handlers.get(event);
    if (set) for (const fn of set) fn({ payload, from, at });
  }

  _error(reason) {
    this._setState("error");
    this.dispatchEvent(new CustomEvent("message", { detail: { event: "error", payload: { reason }, from: "system", at: now() } }));
  }
}

// ── Real transport: a Host WebSocket to the BEAM (Phoenix Presence/PubSub) ────
class SocketTransport {
  constructor(channel) { this.ch = channel; this.ws = null; }
  start() {
    try {
      this.ws = this.ch._host.socket("/live/" + encodeURIComponent(this.ch.topic), {
        onMessage: (raw) => this._recv(raw),
      });
      this.ws.addEventListener("open", () => this._send({ t: "join", meta: this.ch._meta }));
      this.ws.addEventListener("error", () => this.ch._error("socket"));
      this.ws.addEventListener("close", () => { if (this.ch.state !== "closed") this.ch._setState("error"); });
    } catch (e) {
      // No runtime / socket refused → degrade to the mock so the UI still works.
      this.ch._mock = true;
      this.ch._transport = new MockTransport(this.ch);
      this.ch._transport.start();
    }
  }
  _ref() { return ++this.ch._ref; }
  _send(frame) {
    if (this.ws?.readyState === 1) this.ws.send(JSON.stringify({ topic: this.ch.topic, ref: this._ref(), ...frame }));
  }
  _recv(raw) {
    let m; try { m = typeof raw === "string" ? JSON.parse(raw) : raw; } catch { return; }
    switch (m.t) {
      case "joined": return this.ch._joined(m.presence || []);
      case "presence": return this.ch._presenceDiff({ joins: m.joins, leaves: m.leaves });
      case "message": return this.ch._deliver(m);
      case "error": return this.ch._error(m.reason);
    }
  }
  publish(frame) { this._send({ t: "publish", event: frame.event, payload: frame.payload }); }
  track(meta) { this._send({ t: "track", meta }); }
  leave() { this._send({ t: "leave" }); }
  close() { try { this.ws?.close(); } catch {} this.ws = null; }
}

// ── Mock transport: BroadcastChannel across tabs/peers on this machine ────────
// Mirrors the BEAM semantics: a shared bus + heartbeat-based presence so the
// elements demo true multi-participant presence with zero backend. Each tab is a
// distinct client; presence is reconstructed from periodic "hello" heartbeats and
// an explicit "bye" on unload — the same join/leave shape Phoenix Presence emits.
class MockTransport {
  constructor(channel) {
    this.ch = channel;
    this.bus = null;
    this._seen = new Map();   // id -> { id, meta, online_at, last }
    this._hb = null;
    this._gc = null;
  }
  _key() { return "wb-live:" + this.ch.topic; }
  start() {
    try { this.bus = new BroadcastChannel(this._key()); }
    catch { this.bus = new LocalBus(this._key()); } // very old/SSR fallback: self-only
    this.bus.addEventListener("message", (e) => this._recv(e.data));

    // announce + ask who's here
    this._self().online_at = now();
    this._post({ t: "hello", from: this.ch.id, meta: this.ch._meta, online_at: this._self().online_at });
    this._post({ t: "ping", from: this.ch.id });

    // seed our own presence immediately, then settle a snapshot
    this._note(this.ch.id, this.ch._meta, this._self().online_at);
    setTimeout(() => this.ch._joined([...this._seen.values()].map(({ id, meta, online_at }) => ({ id, meta, online_at }))), 60);

    this._hb = setInterval(() => this._post({ t: "hello", from: this.ch.id, meta: this.ch._meta, online_at: this._self().online_at }), 2500);
    this._gc = setInterval(() => this._sweep(), 1500);
    this._bye = () => this._post({ t: "bye", from: this.ch.id });
    window.addEventListener("pagehide", this._bye);
    window.addEventListener("beforeunload", this._bye);
  }
  _self() { return (this._me ||= { id: this.ch.id, online_at: now() }); }
  _post(m) { try { this.bus?.postMessage(m); } catch {} }
  _note(id, meta, online_at) {
    const had = this._seen.has(id);
    this._seen.set(id, { id, meta: meta || {}, online_at: online_at || now(), last: now() });
    if (!had && this.ch.state === "joined") this.ch._presenceDiff({ joins: [{ id, meta: meta || {}, online_at }], leaves: [] });
  }
  _drop(id) {
    if (this._seen.delete(id) && this.ch.state === "joined") this.ch._presenceDiff({ joins: [], leaves: [{ id }] });
  }
  _sweep() {
    const cutoff = now() - 7000;
    for (const [id, p] of this._seen) if (id !== this.ch.id && p.last < cutoff) this._drop(id);
  }
  _recv(m) {
    if (!m || m.from === this.ch.id) {
      // ignore our own broadcasts EXCEPT a peer's reply ping is from others
      if (m && m.t === "ping" && m.from === this.ch.id) return;
      if (m && m.from === this.ch.id) return;
    }
    switch (m.t) {
      case "hello": return this._note(m.from, m.meta, m.online_at);
      case "ping":  return this._post({ t: "hello", from: this.ch.id, meta: this.ch._meta, online_at: this._self().online_at });
      case "bye":   return this._drop(m.from);
      case "track": return this._note(m.from, m.meta, this._seen.get(m.from)?.online_at);
      case "pub":   return this.ch._deliver({ event: m.event, payload: m.payload, from: m.from, at: m.at });
    }
  }
  publish(frame) {
    // mock self-delivers so the publisher sees its own message (Phoenix default too)
    this.ch._deliver(frame);
    this._post({ t: "pub", from: this.ch.id, event: frame.event, payload: frame.payload, at: frame.at });
  }
  track(meta) {
    this._note(this.ch.id, meta, this._self().online_at);
    this._post({ t: "track", from: this.ch.id, meta });
  }
  leave() { this._bye?.(); }
  close() {
    clearInterval(this._hb); clearInterval(this._gc);
    window.removeEventListener("pagehide", this._bye);
    window.removeEventListener("beforeunload", this._bye);
    try { this.bus?.close?.(); } catch {}
    this.bus = null;
  }
}

// Minimal self-only bus for environments without BroadcastChannel.
class LocalBus extends EventTarget {
  postMessage() { /* self-only; no peers */ }
  close() {}
}

// ── Channel pool: one connection per topic over the active Host ───────────────
const _pool = new Map();

/** Get/open the shared channel for a topic (pooled per topic). */
export function openChannel(topic, opts = {}) {
  let ch = _pool.get(topic);
  if (!ch) { ch = new Channel(topic, opts); _pool.set(topic, ch); }
  else if (opts.meta) ch._meta = { ...ch._meta, ...opts.meta };
  return ch;
}

/** Force a fresh channel (e.g. a demo seeding a mock) — replaces the pooled one. */
export function configureChannel(topic, opts = {}) {
  const prev = _pool.get(topic);
  prev?.close();
  const ch = new Channel(topic, opts);
  _pool.set(topic, ch);
  return ch;
}
