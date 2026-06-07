/**
 * PresenceClient — runner-side WebSocket + WebRTC mesh manager
 * for Live URL presence (wb-v9ys.6).
 *
 * Responsibilities:
 *  - Open the WS to /v1/rooms/<slug>/ws (with ?t=<token> when
 *    password-mode), send presence.hello, maintain the roster.
 *  - For each peer in the roster, build a WebRTC RTCPeerConnection
 *    + DataChannel via signaling.offer/answer/ice over the WS.
 *  - Broadcast my own cursor position (x_pct, y_pct in 0..1) over
 *    every open DataChannel.
 *  - Receive remote cursor positions and surface them via the
 *    `peers` reactive map.
 *  - Receive `comment.*` events and forward them to onComment().
 *
 * The DC is the hot path — cursors at ~30fps over WS would balloon
 * broker bandwidth. The WS is the cold path — roster, signaling,
 * comments. If WebRTC handshake fails for any peer, we keep them
 * in the roster but skip the cursor render for that one.
 *
 * Mesh limit is documented at the broker side (50 connections per
 * room, but WebRTC mesh degrades past ~10–15). No SFU in v1.
 */

import { env } from "$env/dynamic/public";

const BROKER_URL = env.PUBLIC_BROKER_URL ?? "https://auth.workbooks.sh";

const RTC_CONFIG: RTCConfiguration = {
  // Use Google's public STUN. No TURN for v1 — recipients on
  // restrictive NATs lose presence but the runner still works.
  iceServers: [{ urls: "stun:stun.l.google.com:19302" }],
};

export interface Peer {
  peer_id: string;
  name: string;
  color: string;
  /** Latest cursor position in [0, 1] viewport coordinates. */
  cursor: { x: number; y: number; t: number } | null;
  /** Timestamp of this peer's most recent click ping. The overlay
   *  renders a brief ripple when this is recent. */
  pingAt: number | null;
}

export interface CommentEvent {
  type: "comment.created" | "comment.updated" | "comment.deleted";
  comment?: unknown;
  id?: string;
}

export interface PresenceClientOpts {
  slug: string;
  name: string;
  color: string;
  /** Unlock token for password-mode rooms (omit otherwise). */
  unlockToken?: string;
  onPeersChange(peers: Peer[]): void;
  onComment?(ev: CommentEvent): void;
  onError?(msg: string): void;
}

interface OutgoingMessage {
  type: string;
  [k: string]: unknown;
}

export class PresenceClient {
  private opts: PresenceClientOpts;
  private ws: WebSocket | null = null;
  private myPeerId: string | null = null;
  private peers = new Map<string, Peer>();
  private peerConnections = new Map<string, RTCPeerConnection>();
  private dataChannels = new Map<string, RTCDataChannel>();
  private cursorRafId: number | null = null;
  private latestCursor: { x: number; y: number } | null = null;
  private closing = false;

  constructor(opts: PresenceClientOpts) {
    this.opts = opts;
  }

  connect(): void {
    const wsBase = BROKER_URL.replace(/^http/, "ws");
    const url = new URL(`${wsBase}/v1/rooms/${encodeURIComponent(this.opts.slug)}/ws`);
    if (this.opts.unlockToken) url.searchParams.set("t", this.opts.unlockToken);
    const ws = new WebSocket(url.toString());
    this.ws = ws;
    ws.addEventListener("open", () => this.onOpen());
    ws.addEventListener("message", (ev) => this.onMessage(ev));
    ws.addEventListener("close", () => this.onClose());
    ws.addEventListener("error", () => this.opts.onError?.("ws_error"));
  }

  close(): void {
    this.closing = true;
    if (this.cursorRafId != null) cancelAnimationFrame(this.cursorRafId);
    for (const dc of this.dataChannels.values()) {
      try { dc.close(); } catch { /* */ }
    }
    for (const pc of this.peerConnections.values()) {
      try { pc.close(); } catch { /* */ }
    }
    this.dataChannels.clear();
    this.peerConnections.clear();
    try { this.ws?.close(); } catch { /* */ }
  }

  /** Push the local cursor position to peers. Coordinates are in
   *  the [0, 1] viewport space so they translate across different
   *  screen sizes. Throttled implicitly by the rAF loop. */
  setLocalCursor(x: number, y: number): void {
    this.latestCursor = { x, y };
    if (this.cursorRafId == null) {
      this.cursorRafId = requestAnimationFrame(() => this.flushCursor());
    }
  }

  /** Broadcast a click ping at the given position. Sent immediately
   *  (not rAF-batched) over every open DC + WS so peers see the
   *  ripple promptly. */
  sendClick(x: number, y: number): void {
    const payload = { x, y, ping: true };
    const json = JSON.stringify(payload);
    let dcSent = 0;
    for (const dc of this.dataChannels.values()) {
      if (dc.readyState === "open") {
        try { dc.send(json); dcSent++; } catch { /* */ }
      }
    }
    if (dcSent < this.peers.size) {
      this.send({ type: "presence.cursor", payload });
    }
  }

  // ── WS lifecycle ────────────────────────────────────────────────

  private onOpen(): void {
    this.send({
      type: "presence.hello",
      name: this.opts.name,
      color: this.opts.color,
    });
  }

  private onClose(): void {
    if (this.closing) return;
    // Best-effort reconnect once after a short backoff.
    setTimeout(() => {
      if (!this.closing) this.connect();
    }, 1500);
  }

  private onMessage(ev: MessageEvent): void {
    let msg: { type?: string; [k: string]: unknown };
    try { msg = JSON.parse(ev.data.toString()); }
    catch { return; }
    if (typeof msg.type !== "string") return;

    switch (msg.type) {
      case "hello":
        this.myPeerId = String(msg.peer_id);
        break;
      case "presence.list":
        this.applyRoster(msg.peers as Peer[]);
        // For each other peer, initiate a WebRTC offer. The lexically
        // smaller peer_id is the offerer to avoid double-offers.
        for (const p of (msg.peers as Peer[]) ?? []) {
          if (p.peer_id === this.myPeerId) continue;
          if (this.myPeerId && this.myPeerId < p.peer_id) this.initiateOffer(p.peer_id);
        }
        break;
      case "presence.join":
        this.applyJoin(msg.peer as Peer);
        // The newly-joined peer initiates if its id is lexically smaller.
        // The existing one (us) waits for their offer.
        break;
      case "presence.bye":
        this.applyBye(String(msg.peer_id));
        break;
      case "signaling.offer":
        void this.handleOffer(String(msg.from), msg.payload as RTCSessionDescriptionInit);
        break;
      case "signaling.answer":
        void this.handleAnswer(String(msg.from), msg.payload as RTCSessionDescriptionInit);
        break;
      case "signaling.ice":
        void this.handleIce(String(msg.from), msg.payload as RTCIceCandidateInit);
        break;
      case "presence.cursor":
        // WS-fallback cursor — used when WebRTC failed.
        this.applyRemoteCursor(String(msg.from), msg.payload as { x: number; y: number; ping?: boolean });
        break;
      case "comment.created":
      case "comment.updated":
      case "comment.deleted":
        this.opts.onComment?.(msg as CommentEvent);
        break;
    }
  }

  private send(msg: OutgoingMessage): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;
    try { this.ws.send(JSON.stringify(msg)); }
    catch { /* dropped; close handler will reconnect */ }
  }

  // ── Roster ──────────────────────────────────────────────────────

  private applyRoster(list: Peer[]): void {
    const next = new Map<string, Peer>();
    for (const p of list) {
      const existing = this.peers.get(p.peer_id);
      next.set(p.peer_id, {
        peer_id: p.peer_id,
        name: p.name,
        color: p.color,
        cursor: existing?.cursor ?? null,
        pingAt: existing?.pingAt ?? null,
      });
    }
    this.peers = next;
    this.emitPeers();
  }

  private applyJoin(p: Peer): void {
    this.peers.set(p.peer_id, { ...p, cursor: null, pingAt: null });
    this.emitPeers();
  }

  private applyBye(peer_id: string): void {
    this.peers.delete(peer_id);
    this.tearDownPc(peer_id);
    this.emitPeers();
  }

  private applyRemoteCursor(peer_id: string, c: { x: number; y: number; ping?: boolean }): void {
    const p = this.peers.get(peer_id);
    if (!p) return;
    p.cursor = { x: c.x, y: c.y, t: Date.now() };
    if (c.ping) p.pingAt = Date.now();
    this.emitPeers();
  }

  private emitPeers(): void {
    this.opts.onPeersChange(
      Array.from(this.peers.values()).filter((p) => p.peer_id !== this.myPeerId),
    );
  }

  // ── WebRTC ──────────────────────────────────────────────────────

  private makePc(remoteId: string): RTCPeerConnection {
    const pc = new RTCPeerConnection(RTC_CONFIG);
    pc.onicecandidate = (ev) => {
      if (ev.candidate) {
        this.send({
          type: "signaling.ice",
          to: remoteId,
          payload: ev.candidate.toJSON(),
        });
      }
    };
    pc.ondatachannel = (ev) => this.wireDataChannel(remoteId, ev.channel);
    this.peerConnections.set(remoteId, pc);
    return pc;
  }

  private async initiateOffer(remoteId: string): Promise<void> {
    if (this.peerConnections.has(remoteId)) return;
    const pc = this.makePc(remoteId);
    const dc = pc.createDataChannel("cursor", { ordered: false, maxRetransmits: 0 });
    this.wireDataChannel(remoteId, dc);
    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    this.send({ type: "signaling.offer", to: remoteId, payload: offer });
  }

  private async handleOffer(from: string, payload: RTCSessionDescriptionInit): Promise<void> {
    let pc = this.peerConnections.get(from);
    if (!pc) pc = this.makePc(from);
    await pc.setRemoteDescription(payload);
    const answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    this.send({ type: "signaling.answer", to: from, payload: answer });
  }

  private async handleAnswer(from: string, payload: RTCSessionDescriptionInit): Promise<void> {
    const pc = this.peerConnections.get(from);
    if (!pc) return;
    try { await pc.setRemoteDescription(payload); } catch { /* stale */ }
  }

  private async handleIce(from: string, payload: RTCIceCandidateInit): Promise<void> {
    const pc = this.peerConnections.get(from);
    if (!pc) return;
    try { await pc.addIceCandidate(payload); } catch { /* */ }
  }

  private wireDataChannel(remoteId: string, dc: RTCDataChannel): void {
    this.dataChannels.set(remoteId, dc);
    dc.onmessage = (ev) => {
      try {
        const m = JSON.parse(ev.data.toString());
        if (typeof m?.x === "number" && typeof m?.y === "number") {
          this.applyRemoteCursor(remoteId, m);
        }
      } catch { /* ignore */ }
    };
    dc.onclose = () => {
      if (this.dataChannels.get(remoteId) === dc) this.dataChannels.delete(remoteId);
    };
  }

  private tearDownPc(remoteId: string): void {
    const dc = this.dataChannels.get(remoteId);
    if (dc) { try { dc.close(); } catch { /* */ } }
    this.dataChannels.delete(remoteId);
    const pc = this.peerConnections.get(remoteId);
    if (pc) { try { pc.close(); } catch { /* */ } }
    this.peerConnections.delete(remoteId);
  }

  // ── Cursor flush ────────────────────────────────────────────────

  private flushCursor(): void {
    this.cursorRafId = null;
    if (!this.latestCursor) return;
    const payload = { x: this.latestCursor.x, y: this.latestCursor.y };

    // Prefer DC for every connected peer; fall back to WS for the
    // others so the roster sees movement even when handshake failed.
    let dcSent = 0;
    const json = JSON.stringify(payload);
    for (const dc of this.dataChannels.values()) {
      if (dc.readyState === "open") {
        try { dc.send(json); dcSent++; } catch { /* */ }
      }
    }
    // If any peer doesn't have an open DC, send via WS so the DO
    // relays a presence.cursor to them.
    if (dcSent < this.peers.size) {
      this.send({ type: "presence.cursor", payload });
    }
  }
}
