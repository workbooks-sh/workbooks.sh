// live.js — the live-shapes client bridge.
//
// This is the seam between the Studio SPA and the runtime's real-time substrate (Nexus.Shapes +
// Nexus.Presence, exposed over the /ws WebSocket). The SPA renders from a local cache; the server
// pushes resource deltas and presence snapshots; this module turns those frames into callbacks the
// Svelte views subscribe to. It is intentionally framework-free (plain JS + a tiny pub/sub) so it can
// back either the mock store (dev) or a live runtime (prod) behind the same API.
//
// Wire protocol (matches nexus/lib/ws.ex):
//   → {op:"shape", name, scope}              ← {type:"shape:init", name, rows} then {type:"shape:delta", name, op, row}
//   → {op:"presence", channel, state}        ← {type:"presence", here:[...]}
//   → {op:"ping"}                            ← {type:"pong"}

const RECONNECT_MS = 1500
const PING_MS = 20000

export class LiveClient {
  constructor(url) {
    this.url = url || defaultWsUrl()
    this.ws = null
    this.ready = false
    this.queue = [] // frames buffered until the socket opens
    this.shapeHandlers = new Map() // name -> Set(fn)
    this.presenceHandlers = new Map() // channel -> Set(fn)
    this._pingTimer = null
  }

  connect() {
    if (this.ws) return this
    try {
      this.ws = new WebSocket(this.url)
    } catch (e) {
      this._scheduleReconnect()
      return this
    }
    this.ws.onopen = () => {
      this.ready = true
      this.queue.splice(0).forEach((f) => this._raw(f))
      // re-arm subscriptions after a reconnect
      for (const name of this.shapeHandlers.keys()) this._raw({ op: 'shape', name })
      for (const ch of this.presenceHandlers.keys()) this._raw({ op: 'presence', channel: ch })
      this._pingTimer = setInterval(() => this._raw({ op: 'ping' }), PING_MS)
    }
    this.ws.onmessage = (ev) => this._onFrame(ev.data)
    this.ws.onclose = () => {
      this.ready = false
      clearInterval(this._pingTimer)
      this.ws = null
      this._scheduleReconnect()
    }
    this.ws.onerror = () => {
      try { this.ws.close() } catch (_) {}
    }
    return this
  }

  // Subscribe to a live shape (a registered resource name, optionally scoped to a channel/workspace).
  // handlers: { init(rows), delta({op, row}) }. Returns an unsubscribe fn.
  subscribeShape(name, scope, handlers) {
    const set = this.shapeHandlers.get(name) || new Set()
    set.add(handlers)
    this.shapeHandlers.set(name, set)
    this._send({ op: 'shape', name, scope })
    return () => {
      set.delete(handlers)
      if (set.size === 0) this.shapeHandlers.delete(name)
    }
  }

  // Subscribe to presence for a channel. handler(here[]) gets the live roster. Returns unsubscribe.
  subscribePresence(channel, handler) {
    const set = this.presenceHandlers.get(channel) || new Set()
    set.add(handler)
    this.presenceHandlers.set(channel, set)
    this._send({ op: 'presence', channel })
    return () => {
      set.delete(handler)
      if (set.size === 0) this.presenceHandlers.delete(channel)
    }
  }

  // Announce that I'm present / typing in a channel.
  touch(channel, state = 'online') {
    this._send({ op: 'presence', channel, state })
  }

  disconnect() {
    clearInterval(this._pingTimer)
    if (this.ws) { try { this.ws.close() } catch (_) {} }
    this.ws = null
  }

  // ── internals ──────────────────────────────────────────────────────────────────────────────────

  _onFrame(data) {
    let msg
    try { msg = JSON.parse(data) } catch (_) { return }
    switch (msg.type) {
      case 'shape:init': {
        const set = this.shapeHandlers.get(msg.name)
        if (set) for (const h of set) h.init && h.init(msg.rows || [])
        break
      }
      case 'shape:delta': {
        const set = this.shapeHandlers.get(msg.name)
        if (set) for (const h of set) h.delta && h.delta({ op: msg.op, row: msg.row })
        break
      }
      case 'presence': {
        // a presence frame isn't tagged with its channel by the server; fan out to all presence subs
        // that asked (each filters by its own channel-scoped roster on its side if needed)
        for (const set of this.presenceHandlers.values()) for (const h of set) h(msg.here || [])
        break
      }
      // pong / error frames are ignored
    }
  }

  _send(frame) {
    if (this.ready) this._raw(frame)
    else this.queue.push(frame)
  }

  _raw(frame) {
    try { this.ws.send(JSON.stringify(frame)) } catch (_) {}
  }

  _scheduleReconnect() {
    setTimeout(() => this.connect(), RECONNECT_MS)
  }
}

function defaultWsUrl() {
  if (typeof window === 'undefined') return 'ws://localhost:4000/ws'
  const proto = window.location.protocol === 'https:' ? 'wss:' : 'ws:'
  return `${proto}//${window.location.host}/ws`
}

// A lazily-created shared client the views import. In dev (no runtime) the socket simply keeps
// retrying in the background and the SPA falls back to its local store — nothing blocks on it.
let _shared = null
export function live() {
  if (!_shared) _shared = new LiveClient().connect()
  return _shared
}
