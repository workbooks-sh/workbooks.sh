// Runtime WS bridge to the local Elixir runtime (graceful-offline).
//
// Connects to the Phoenix endpoint the daemon (src-tauri/src/daemon.rs)
// boots on localhost. Lifecycle is driven off `daemon.status`: connect
// once it lands `ready` (native `running`), disconnect when it stops.
// The per-boot bearer token from discovery is attached to the socket and
// to the run POST. The agent's WS shape today (per runtime/host
// agent/lib/agent/web/{user_socket,session_channel,runtime_channel}.ex):
//
//   socket "/socket" → topic `session:<session_id>` (per-session telemetry)
//                    → topic `runtime:telemetry`  (global fan-out, wb-i38o.18)
//
// `runtime:telemetry` re-broadcasts every session's events under the
// channel event name `"event"` with envelope:
//   { session_id, event_type, ts, payload }
//
// The bridge joins it on first connect so the kanban (D5) and any other
// "fleet view" surface can subscribe without knowing session ids in
// advance. Per-session channels still work — they're additive.
//
// `sendUserInput()` POSTs `/api/run` with the user's text as the prompt;
// the new session's id is also joined as a fresh `session:<id>` channel
// so chat-tab telemetry streams without the round-trip through the
// global topic.

// Type-only import (erased at build) + a lazy value import in #connect, so
// phoenix is dropped from the entry/release chunk (wb-aakl.13). The Phoenix
// telemetry bridge is the dead control-plane path (the runtime has no
// Phoenix); it's kept but code-split until the transport re-point. `Channel`
// is type-only already — sock.channel() returns it; there is no `new Channel`.
import type { Socket as PhoenixSocket, Channel } from "phoenix";
import { daemon } from "./sidecar.svelte";
// `package` and `agents` are NOT imported here on purpose. ws is a
// peer store that emits + accepts events; importing them statically
// creates a four-way cycle (ws ↔ agents ↔ package ↔ agent_settings)
// that breaks tree-shaking and triggers ESM init warnings. The two
// values we read from them — active workdir + selected agent slug —
// flow through `bridge/_active.svelte.ts` instead: agents writes
// `active.agentSlug` on selection, package writes `active.workdir`
// on activation, and ws reads them at call time.
import { active } from "./_active.svelte";

// wb-i38o.2 + wb-mkqx + wb-shtl — fallback agent when the selection
// store hasn't resolved one yet (cold start, sidecar not booted, etc.).
// Once the picker is mounted this is rarely the value used — the
// active selection from `agents.selected` overrides it.
const FALLBACK_AGENT_SLUG = "workhorse";

// Dev/single-tenant tenant for the `x-tenant` Auth-plug fallback (used only
// when no per-boot bearer is present — i.e. the VITE_WB_RUNTIME_URL override).
const DEV_TENANT = (import.meta.env.VITE_WB_TENANT as string | undefined) || "dev";

// Demo / foreground-create fallback workdir (FIX B). When no Package is
// active, a foreground chat has no `active.workdir`, so the runtime would
// drop the agent's vfs_write into an ephemeral per-run tmp dir the desktop
// preview can't read — the right split pane comes up blank. The desktop is
// the trusted, single-tenant caller and MAY name its own workdir on
// POST /api/agent/run (web.ex effective_workdir honors it), so we pin a
// STABLE host folder under the repo (reachable via Vite /@fs/ for the
// read_file_text → preview path). Overridable via VITE_WB_DEMO_WORKDIR.
const DEMO_WORKDIR =
  (import.meta.env.VITE_WB_DEMO_WORKDIR as string | undefined) ||
  "/Users/shinyobjectz/Apps/workbooks/runtime/.demo-workspace";

export interface BridgeEvent {
  // Phoenix-channel event name (e.g. "session_started", "llm_turn_start").
  // We also synthesize bridge-level events: "bridge:connected",
  // "bridge:disconnected", "bridge:error", "bridge:joined", "bridge:tx".
  name: string;
  payload: unknown;
  topic: string;
  /** Originating session id when the event came in on `runtime:telemetry`.
   *  Null for per-session topic events (use `topic` to derive) and for
   *  bridge-level events. */
  sessionId: string | null;
  /** Server-side wall-clock from the runtime envelope when present, else
   *  the time the bridge received the frame. Always millis since epoch. */
  ts: number;
  receivedAt: number;
}

type Handler = (e: BridgeEvent) => void;

interface PartialEvent {
  name: string;
  payload: unknown;
  topic: string;
  sessionId?: string | null;
  ts?: number;
}

const PROBE_TOPIC = "session:desktop-bridge-probe";

// wb-i38o.18 — runtime-wide telemetry fanout for the kanban + ops views.
const RUNTIME_TOPIC = "runtime:telemetry";

/** Envelope pushed by RuntimeChannel under event name `"event"`. */
interface RuntimeEnvelope {
  session_id: string;
  event_type: string;
  ts: number;
  payload: unknown;
}

function isRuntimeEnvelope(v: unknown): v is RuntimeEnvelope {
  if (!v || typeof v !== "object") return false;
  const o = v as Record<string, unknown>;
  return (
    typeof o.session_id === "string" &&
    typeof o.event_type === "string" &&
    typeof o.ts === "number"
  );
}

// wb-i38o.12 — workbook-as-memory result shapes. Consumed by the REST
// surface in `memory_sources.svelte.ts` (/api/memory/sources), not a channel.
export interface AddWorkbookResult {
  workbook_path: string;
  file_count: number;
  indexed_count: number;
}

export interface RemoveWorkbookResult {
  file_count: number;
  entry_count: number;
}

export interface ListWorkbooksResult {
  workbooks: string[];
}

class WsBridgeStore {
  events = $state<BridgeEvent[]>([]);
  count = $state(0);
  connected = $state(false);
  lastError = $state<string | null>(null);

  #socket: PhoenixSocket | null = null;
  #channels = new Map<string, Channel>();
  #handlers = new Set<Handler>();
  #initStarted = false;
  #lastUrl: string | null = null;
  // The per-boot token we last connected with. A runtime RESTART keeps the same
  // url but rotates this token; without tracking it the bridge would keep using
  // the dead token and never re-authenticate against the new runtime.
  #lastToken: string | null = null;

  init() {
    if (this.#initStarted) return;
    this.#initStarted = true;
    // React to daemon state — connect once `ready` lands, disconnect
    // when it stops/goes unhealthy, reconnect on next ready.
    $effect.root(() => {
      $effect(() => {
        const { state, url, token } = daemon.status;
        // Reconnect when the endpoint OR the per-boot token changes — a runtime
        // restart keeps the url but rotates the token, and a fast restart can
        // skip the unhealthy beat entirely, so url-only would miss it.
        if (state === "ready" && url && (url !== this.#lastUrl || token !== this.#lastToken)) {
          void this.#connect(url, token);
        } else if (state === "stopped" || state === "unhealthy") {
          this.#disconnect();
        }
      });
    });
  }

  subscribe(h: Handler): () => void {
    this.#handlers.add(h);
    return () => this.#handlers.delete(h);
  }

  /** Inject a synthetic bridge event into the local handler set. Used by
   *  the browser-preview mock agent (webHost) to drive the chat surface
   *  without a live runtime/Phoenix socket — the real transport never
   *  calls this. Mirrors the runtime's per-session telemetry shape. */
  emitLocal(name: string, payload: unknown, topic: string): void {
    this.#emit({ name, payload, topic });
  }

  /** Start a session by POSTing the user's text as a prompt to /api/run.
   *  Returns the new session_id on success; throws on failure.
   *
   *  `opts.agentSlug` overrides `agents.selected` for this one call —
   *  used by the Planning Wizard's follow-on flow (wb-lueb) where the
   *  wizard's configured executor agent may differ from the chat
   *  picker's current selection. */
  async sendUserInput(
    text: string,
    opts: { agentSlug?: string | null; skills?: string[] } = {},
  ): Promise<string> {
    const { url, token } = daemon.status;
    if (!url) throw new Error("daemon not ready — no URL yet");

    // Prefer the active Package's folder; otherwise pin the stable demo
    // workdir so the agent writes the workbook to a known host path the
    // preview can read back (FIX B) instead of an ephemeral tmp run dir.
    const workdir = active.workdir ?? DEMO_WORKDIR;
    const agent_slug = opts.agentSlug ?? active.agentSlug ?? FALLBACK_AGENT_SLUG;
    const reqBody: Record<string, unknown> = {
      agent_slug,
      prompt: text,
    };
    if (workdir) reqBody.workdir = workdir;
    if (opts.skills && opts.skills.length > 0) reqBody.skills = opts.skills;

    // New slug-resolving endpoint (returns {session_id}); avoids the
    // legacy POST /api/run shape ({system,task,max_steps,model}).
    // When no per-boot bearer is present (dev runtime override / single-tenant
    // dev), carry the `x-tenant` dev header so the runtime's Auth plug scopes
    // the run to our tenant. A bearer, when present, supersedes it.
    const r = await fetch(`${url}/api/agent/run`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        ...(token ? { Authorization: `Bearer ${token}` } : { "x-tenant": DEV_TENANT }),
      },
      body: JSON.stringify(reqBody),
    });
    const body = await r.json().catch(() => ({}));
    if (!r.ok) {
      const msg = `POST /api/agent/run ${r.status}: ${JSON.stringify(body)}`;
      this.#emit({ name: "bridge:error", payload: { msg }, topic: "bridge" });
      throw new Error(msg);
    }
    const session_id: string = body.session_id;
    this.#emit({
      name: "bridge:tx",
      payload: { text, session_id, agent: agent_slug, workdir },
      topic: "bridge",
    });
    // Join the new session's channel so subsequent telemetry flows in.
    this.#join(`session:${session_id}`);
    return session_id;
  }

  // ── internals ──

  async #connect(httpUrl: string, token: string | null) {
    this.#disconnect();
    this.#lastUrl = httpUrl;
    this.#lastToken = token;
    const wsUrl = httpUrl.replace(/^http/, "ws") + "/socket";
    // Lazy-load phoenix only when actually connecting — keeps it out of the
    // entry chunk (wb-aakl.13).
    const { Socket } = await import("phoenix");
    const sock = new Socket(wsUrl, {
      // Per-boot bearer token from discovery — UserSocket.connect/3
      // authenticates the socket from these params.
      params: token ? { token } : {},
      // Be quieter than Phoenix's default logger in dev.
      logger: () => {},
      // Back off hard. A simplified runtime may not serve /socket (telemetry +
      // agent tab-control channels); without this, Phoenix's default curve
      // settles to a 5s retry and spams the console. Try a couple of quick
      // reconnects, then a slow 30s heartbeat so a runtime that comes to support
      // the socket still reconnects, without hammering one that doesn't.
      reconnectAfterMs: (tries: number) =>
        [1000, 3000, 10000][tries - 1] ?? 30000,
    });
    sock.onOpen(() => {
      this.connected = true;
      this.lastError = null;
      this.#emit({
        name: "bridge:connected",
        payload: { url: wsUrl },
        topic: "bridge",
      });
      this.#join(PROBE_TOPIC);
      // Global runtime telemetry — every session's events fan out here
      // under event name "event" with a { session_id, event_type, ts,
      // payload } envelope (wb-i38o.18). Joined unconditionally so the
      // kanban can show pre-existing sessions on tab switch.
      this.#join(RUNTIME_TOPIC);
    });
    sock.onError((err) => {
      this.lastError = String(err);
      this.#emit({
        name: "bridge:error",
        payload: { err: String(err) },
        topic: "bridge",
      });
    });
    sock.onClose(() => {
      this.connected = false;
      this.#emit({
        name: "bridge:disconnected",
        payload: {},
        topic: "bridge",
      });
    });
    sock.connect();
    this.#socket = sock;
  }

  #disconnect() {
    for (const ch of this.#channels.values()) ch.leave();
    this.#channels.clear();
    this.#socket?.disconnect();
    this.#socket = null;
    this.#lastUrl = null;
    this.#lastToken = null;
  }

  #join(topic: string) {
    if (!this.#socket) return;
    if (this.#channels.has(topic)) return;
    const ch = this.#socket.channel(topic, {});
    // Mirror every push the channel forwards into the store. The
    // SessionChannel push events are: session_started, llm_turn_start,
    // llm_turn_stop, tool_call_start, tool_call_stop, session_persisted,
    // lease_lost, session_completed, session_failed, session_cancelled.
    // We don't enumerate — `onMessage` catches everything.
    ch.onMessage = (event, payload) => {
      // Skip Phoenix protocol noise (`phx_reply`, `phx_close`).
      if (event.startsWith("phx_") || event.startsWith("chan_")) {
        return payload;
      }
      // Runtime fan-out channel: every push is the literal event name
      // `"event"` with a `{ session_id, event_type, ts, payload }`
      // envelope. Unwrap so consumers see the same event_type names
      // they'd see on a per-session topic.
      if (topic === RUNTIME_TOPIC && event === "event") {
        if (isRuntimeEnvelope(payload)) {
          this.#emit({
            name: payload.event_type,
            payload: payload.payload,
            topic: RUNTIME_TOPIC,
            sessionId: payload.session_id,
            ts: payload.ts,
          });
        }
        return payload;
      }
      this.#emit({ name: event, payload, topic });
      return payload;
    };
    ch.join()
      .receive("ok", (resp) => {
        this.#emit({ name: "bridge:joined", payload: resp, topic });
      })
      .receive("error", (resp) => {
        this.#emit({ name: "bridge:error", payload: resp, topic });
      });
    this.#channels.set(topic, ch);
  }

  #emit(partial: PartialEvent) {
    const now = Date.now();
    const e: BridgeEvent = {
      name: partial.name,
      payload: partial.payload,
      topic: partial.topic,
      sessionId: partial.sessionId ?? null,
      ts: partial.ts ?? now,
      receivedAt: now,
    };
    this.count += 1;
    // Bounded ring — keep the most recent 200 events to avoid runaway
    // memory if the agent is chatty.
    if (this.events.length >= 200) this.events = this.events.slice(-199);
    this.events = [...this.events, e];
    for (const h of this.#handlers) h(e);
  }
}

export const ws = new WsBridgeStore();
