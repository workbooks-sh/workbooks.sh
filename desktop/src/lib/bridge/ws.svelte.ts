// Runtime WS bridge to the local Elixir runtime (graceful-offline).
//
// Connects to the Phoenix endpoint the daemon (src-tauri/src/daemon.rs)
// boots on localhost. Lifecycle is driven off `daemon.status`: connect
// once it lands `ready` (native `running`), disconnect when it stops.
// The per-boot bearer token from discovery is attached to the socket and
// to the run POST. The agent's WS shape today (per packages/oql/elixir/
// oql-agent/lib/oql_agent/web/{user_socket,session_channel,runtime_channel}.ex):
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
import { workgate, type WorkgateRequest, type WorkgatePermitDecision } from "$lib/workgate/store.svelte";
import {
  envRequests,
  type EnvRequest,
  type EnvFulfillPayload,
  type EnvCancelPayload,
} from "$lib/env_request/store.svelte";
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
import { tabs } from "$lib/tabs/store.svelte";
import {
  dispatchTabCommand,
  type TabCommandHandlers,
  type TabCommandPayload,
} from "./tab-command-dispatcher";

export type { TabCommandPayload } from "./tab-command-dispatcher";

// wb-i38o.2 + wb-mkqx + wb-shtl — fallback agent when the selection
// store hasn't resolved one yet (cold start, sidecar not booted, etc.).
// Once the picker is mounted this is rarely the value used — the
// active selection from `agents.selected` overrides it.
const FALLBACK_AGENT_SLUG = "workhorse";

// Dev/single-tenant tenant for the `x-tenant` Auth-plug fallback (used only
// when no per-boot bearer is present — i.e. the VITE_WB_RUNTIME_URL override).
const DEV_TENANT = (import.meta.env.VITE_WB_TENANT as string | undefined) || "dev";

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

// wb-i38o.3 — singleton control channel for pushing the active
// workspace FS scope to the Elixir agent.
const WORKSPACE_CONTROL_TOPIC = "workspace:control";
// wb-i38o.11 — outbound control channel: the agent's open_tab /
// close_tab / focus_tab tools broadcast tab_command events; we
// dispatch them to the local Tauri tab commands here.
const DESKTOP_CONTROL_TOPIC = "desktop:control";
// wb-i38o.12 — singleton control channel for managing memory
// sources (workbook-as-memory loader).
const MEMORY_CONTROL_TOPIC = "memory:control";
// wb-80q0.10 — bidirectional control channel for the Workgate
// OS-permission bridge. Inbound: workgate_request events from
// the agent. Outbound: permit messages with the user's Allow/Deny.
const WORKGATE_CONTROL_TOPIC = "workgate:control";
// Bidirectional control channel for env-var provisioning requests
// from `wb env request`. Inbound: env_prompt with name + workspace
// + reason + hint. Outbound: env:fulfill with the value the user
// typed (writes to the workspace keychain) or env:cancel.
const ENV_PROMPT_TOPIC = "engine:env_prompt";
// Single-firehose live-update topic. Every file change under the
// user's data root arrives here as one "file_changed" event with
// payload { path, op, kind, at }. Bridges register interest with
// `onMonorepoChange(pattern, handler)` instead of joining per-path
// channels themselves.
const MONOREPO_WATCH_TOPIC = "monorepo:watch";

interface WorkspaceScopePayload {
  workspace: string | null;
  folders: string[];
}

/** Payload of every `monorepo:watch` `"file_changed"` event. */
export interface MonorepoFileChange {
  /** Absolute path of the file that changed. */
  path: string;
  /** Always `"fs_changed"` from the OS watcher (vs `"transition_todo"`
   *  / `"set_property"` / `"append_logbook"` from the HTTP write
   *  surface). */
  op: string;
  /** `"created"` / `"modified"` / `"removed"` / `"renamed"`. */
  kind: string;
  /** Server-side ms-since-epoch timestamp. */
  at: number;
  /** Watcher events leave this null; HTTP-surface events set the
   *  mutated headline's :ID:. */
  headline_id: string | null;
}

/** Compile a monorepo-pattern string into a path-match predicate.
 *  Supports: exact path, bare filename, `*` (any non-`/` chars),
 *  `**` (any chars including `/`). Anchored to the full path. */
function compileMonorepoPattern(pattern: string): (path: string) => boolean {
  // Bare filename — match against basename anywhere in the tree.
  if (!pattern.includes("/")) {
    return (p: string) => p.endsWith("/" + pattern) || p === pattern;
  }
  // Exact path (no glob chars).
  if (!pattern.includes("*")) {
    return (p: string) => p === pattern;
  }
  // Glob — convert to a regex, anchored.
  const re = new RegExp(
    "^" +
      pattern
        .split(/(\*\*|\*)/)
        .map((part) => {
          if (part === "**") return ".*";
          if (part === "*") return "[^/]*";
          return part.replace(/[.+?^${}()|[\]\\]/g, "\\$&");
        })
        .join("") +
      "$",
  );
  return (p: string) => re.test(p);
}

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

/** Tab-command handlers — routed to the live tabs store in production.
 *  The pure dispatcher in `./tab-command-dispatcher.ts` exists so unit
 *  tests can swap these for spies without booting Phoenix or Svelte. */
export const tabCommandHandlers: TabCommandHandlers = {
  open: (path) => tabs.open(path),
  close: (path) => tabs.closeByPath(path),
  focus: (path) => tabs.focusByPath(path),
};

// wb-i38o.12 — workbook-as-memory result shapes.
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

  /** Push the channel-level `cancel` event for a session. The channel
   *  is expected to already be joined (sendUserInput joins it). Silent
   *  no-op if the session isn't known. */
  cancelSession(session_id: string): void {
    const ch = this.#channels.get(`session:${session_id}`);
    if (!ch) return;
    ch.push("cancel", {})
      .receive("ok", (resp) =>
        this.#emit({
          name: "bridge:tx",
          payload: { kind: "cancel", session_id, resp },
          topic: `session:${session_id}`,
        }),
      )
      .receive("error", (resp) =>
        this.#emit({
          name: "bridge:error",
          payload: { kind: "cancel", session_id, resp },
          topic: `session:${session_id}`,
        }),
      );
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

    const workdir = active.workdir;
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

  /** wb-i38o.3 — push the active workspace scope down the bridge.
   *  Resolves once the WorkspaceControlChannel acks the message; throws
   *  if the channel is missing, not joined yet, or the server rejects. */
  async pushWorkspaceScope(payload: WorkspaceScopePayload): Promise<void> {
    if (!this.#socket) throw new Error("ws bridge: socket not connected");
    let ch = this.#channels.get(WORKSPACE_CONTROL_TOPIC);
    if (!ch) {
      // Lazy-join. The channel is fire-and-forget; we don't need to
      // wait for the "ok" reply on join because the push below will
      // queue until the join finishes (Phoenix client behavior).
      this.#join(WORKSPACE_CONTROL_TOPIC);
      ch = this.#channels.get(WORKSPACE_CONTROL_TOPIC);
    }
    if (!ch) throw new Error("ws bridge: failed to join workspace:control");
    return await new Promise<void>((resolve, reject) => {
      ch!
        .push("set_scope", payload, 5000)
        .receive("ok", () => resolve())
        .receive("error", (resp) =>
          reject(new Error(`set_scope error: ${JSON.stringify(resp)}`)),
        )
        .receive("timeout", () => reject(new Error("set_scope timeout")));
    });
  }

  /** wb-80q0.10 — push the user's Allow/Deny decision back through
   *  the `workgate:control` channel. Fire-and-forget from the
   *  caller's perspective; we only wait for the Phoenix `ok` ack so
   *  errors surface synchronously. */
  async workgatePermit(decision: WorkgatePermitDecision): Promise<void> {
    if (!this.#socket) throw new Error("ws bridge: socket not connected");
    let ch = this.#channels.get(WORKGATE_CONTROL_TOPIC);
    if (!ch) {
      this.#join(WORKGATE_CONTROL_TOPIC);
      ch = this.#channels.get(WORKGATE_CONTROL_TOPIC);
    }
    if (!ch) throw new Error("ws bridge: failed to join workgate:control");
    return await new Promise<void>((resolve, reject) => {
      ch!
        .push("permit", decision, 5000)
        .receive("ok", () => resolve())
        .receive("error", (resp) =>
          reject(new Error(`workgate permit error: ${JSON.stringify(resp)}`)),
        )
        .receive("timeout", () => reject(new Error("workgate permit timeout")));
    });
  }

  /** Push the user's env value into the `engine:env_prompt` channel
   *  as the `env:fulfill` event. Resolves on the Phoenix `ok` ack;
   *  rejects on `error` / `timeout`. */
  async envFulfill(payload: EnvFulfillPayload): Promise<void> {
    if (!this.#socket) throw new Error("ws bridge: socket not connected");
    let ch = this.#channels.get(ENV_PROMPT_TOPIC);
    if (!ch) {
      this.#join(ENV_PROMPT_TOPIC);
      ch = this.#channels.get(ENV_PROMPT_TOPIC);
    }
    if (!ch) throw new Error("ws bridge: failed to join engine:env_prompt");
    return await new Promise<void>((resolve, reject) => {
      ch!
        .push("env:fulfill", payload, 10_000)
        .receive("ok", () => resolve())
        .receive("error", (resp) =>
          reject(new Error(`env:fulfill error: ${JSON.stringify(resp)}`)),
        )
        .receive("timeout", () => reject(new Error("env:fulfill timeout")));
    });
  }

  /** Push a cancel onto the env-prompt channel. */
  async envCancel(payload: EnvCancelPayload): Promise<void> {
    if (!this.#socket) throw new Error("ws bridge: socket not connected");
    let ch = this.#channels.get(ENV_PROMPT_TOPIC);
    if (!ch) {
      this.#join(ENV_PROMPT_TOPIC);
      ch = this.#channels.get(ENV_PROMPT_TOPIC);
    }
    if (!ch) throw new Error("ws bridge: failed to join engine:env_prompt");
    return await new Promise<void>((resolve, reject) => {
      ch!
        .push("env:cancel", payload, 5_000)
        .receive("ok", () => resolve())
        .receive("error", (resp) =>
          reject(new Error(`env:cancel error: ${JSON.stringify(resp)}`)),
        )
        .receive("timeout", () => reject(new Error("env:cancel timeout")));
    });
  }

  /** wb-i38o.12 — push add/remove/list against the `memory:control`
   *  channel. Returns whatever the channel replies with on `ok`.
   *  Throws on `error` / `timeout`. */
  async memoryControl<T>(
    event: "add_workbook" | "remove_workbook" | "list_workbooks",
    payload: Record<string, unknown>,
  ): Promise<T> {
    if (!this.#socket) throw new Error("ws bridge: socket not connected");
    let ch = this.#channels.get(MEMORY_CONTROL_TOPIC);
    if (!ch) {
      this.#join(MEMORY_CONTROL_TOPIC);
      ch = this.#channels.get(MEMORY_CONTROL_TOPIC);
    }
    if (!ch) throw new Error("ws bridge: failed to join memory:control");
    return await new Promise<T>((resolve, reject) => {
      ch!
        .push(event, payload, 10_000)
        .receive("ok", (resp) => resolve(resp as T))
        .receive("error", (resp) =>
          reject(new Error(`${event} error: ${JSON.stringify(resp)}`)),
        )
        .receive("timeout", () => reject(new Error(`${event} timeout`)));
    });
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
      // wb-i38o.11 — auto-join the desktop control channel so the
      // agent's tab-control tools (open_tab / close_tab / focus_tab)
      // can drive the user's tabs.
      this.#join(DESKTOP_CONTROL_TOPIC);
      // wb-80q0.10 — auto-join the Workgate control channel so any
      // os.* capability request from the agent reaches the SvelteKit
      // approval modal immediately on first connect.
      this.#join(WORKGATE_CONTROL_TOPIC);
      // Auto-join the env-prompt channel so `wb env request` from
      // any terminal reaches the SvelteKit modal. The engine counts
      // joins here to decide whether desktop mode is reachable
      // (see EnvBroker.desktop_subscribed?/0).
      this.#join(ENV_PROMPT_TOPIC);
      // Single-firehose live-update channel. Every file change under
      // the user's data root pushes one "file_changed" event here;
      // the path-pattern router below fans it back out to whichever
      // bridges registered an interest. Replaces 15+ per-bridge
      // subscription wirings.
      this.#join(MONOREPO_WATCH_TOPIC);
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
    // wb-i38o.11 — desktop:control's tab_command events need to
    // actually drive the local tab store, not just appear in the
    // bridge event log. Register an explicit dispatcher; the global
    // event mirror above still gets the event for visibility.
    if (topic === DESKTOP_CONTROL_TOPIC) {
      ch.on("tab_command", (payload: TabCommandPayload) => {
        this.#dispatchTabCommand(payload);
      });
      // wb-d2nx.2 — non-tab app capabilities (theme / bookmark / workspace) the
      // agent drives via `wb app …`. Generic action dispatch to the local stores.
      ch.on("app_command", (payload: Record<string, unknown>) => {
        void this.#dispatchAppCommand(payload);
      });
    }
    // wb-80q0.10 — workgate:control's workgate_request events need
    // to enqueue into the workgate store so the modal renders. Same
    // pattern as the tab_command dispatcher.
    if (topic === WORKGATE_CONTROL_TOPIC) {
      ch.on("workgate_request", (payload: WorkgateRequest) => {
        workgate.enqueue(payload);
      });
    }
    // Env-request channel — push `env_prompt` events into the
    // env-request store; the EnvRequestModal subscribes to it.
    if (topic === ENV_PROMPT_TOPIC) {
      ch.on("env_prompt", (payload: EnvRequest) => {
        envRequests.enqueue(payload);
      });
    }
    ch.join()
      .receive("ok", (resp) => {
        this.#emit({ name: "bridge:joined", payload: resp, topic });
      })
      .receive("error", (resp) => {
        this.#emit({ name: "bridge:error", payload: resp, topic });
      });
    this.#channels.set(topic, ch);
  }

  /** wb-i38o.33.3 — subscribe to the per-document live-update channel.
   *  Returns a teardown that leaves the channel. Calling joinDocument
   *  twice for the same path is a no-op (the underlying #join is
   *  idempotent). */
  joinDocument(path: string): () => void {
    const topic = `oql:document:${path}`;
    this.#join(topic);
    return () => {
      const ch = this.#channels.get(topic);
      if (!ch) return;
      ch.leave();
      this.#channels.delete(topic);
    };
  }

  /** Path-pattern router for the single-firehose live-update channel.
   *
   *  The desktop joins `monorepo:watch` automatically on WS connect;
   *  every file change under the user's data root arrives here as
   *  one `"file_changed"` event with `{ path, op, kind, at }`. Bridges
   *  call this to register interest in paths they care about.
   *
   *  Pattern grammar (intentionally minimal):
   *  - Exact path match — `"/Users/me/Workbooks/monorepo/workspaces.org"`
   *  - Filename match — `"agent-settings.org"` (matches any file with
   *    that basename anywhere under the data root)
   *  - Glob with `*` and `**` — `"** /.oql/agents/*.org"` (any
   *    workspace-scope agent definition; space added here just to
   *    sidestep this comment block)
   *
   *  Returns a teardown that removes the handler. */
  onMonorepoChange(
    pattern: string,
    handler: (payload: MonorepoFileChange) => void,
  ): () => void {
    const matcher = compileMonorepoPattern(pattern);
    const wrapper: Handler = (e) => {
      if (e.topic !== MONOREPO_WATCH_TOPIC) return;
      if (e.name !== "file_changed") return;
      const payload = e.payload as MonorepoFileChange;
      if (matcher(payload.path)) handler(payload);
    };
    this.#handlers.add(wrapper);
    return () => {
      this.#handlers.delete(wrapper);
    };
  }

  #dispatchTabCommand(payload: TabCommandPayload) {
    // Fire-and-forget: the agent already received its tool-result
    // "ok" from the Elixir side; this side is the host renderer.
    // We surface failures on the event log so the dev can see them.
    dispatchTabCommand(payload, tabCommandHandlers).then((result) => {
      if (!result.ok) {
        this.#emit({
          name: "bridge:error",
          payload: { kind: "tab_command", ...result },
          topic: DESKTOP_CONTROL_TOPIC,
        });
      } else {
        this.#emit({
          name: "bridge:tx",
          payload: { kind: "tab_command", ...result },
          topic: DESKTOP_CONTROL_TOPIC,
        });
      }
    });
  }

  // wb-d2nx.2 — dispatch a non-tab app_command to the right local store. Lazy
  // store imports keep them out of the bridge's eager graph.
  async #dispatchAppCommand(payload: Record<string, unknown>) {
    const action = String(payload.action ?? "");
    try {
      if (action === "set_theme") {
        const { themes } = await import("$lib/bridge/themes.svelte");
        await themes.setActive(String(payload.id ?? ""));
      } else if (action === "bookmark") {
        const { bookmarks } = await import("$lib/bridge/bookmarks.svelte");
        await bookmarks.create(String(payload.title ?? payload.path ?? "Bookmark"), String(payload.path ?? ""));
      } else if (action === "new_workspace") {
        const { workspaces } = await import("$lib/bridge/workspaces.svelte");
        await workspaces.create(String(payload.name ?? "Workspace"), String(payload.icon ?? ""));
      } else {
        return;
      }
      this.#emit({ name: "bridge:tx", payload: { kind: "app_command", action }, topic: DESKTOP_CONTROL_TOPIC });
    } catch (err) {
      this.#emit({ name: "bridge:error", payload: { kind: "app_command", action, error: String(err) }, topic: DESKTOP_CONTROL_TOPIC });
    }
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

// wb-80q0.10 — let the workgate store push permits back through us.
// Module-level binding (not a constructor arg) so tests can swap
// either side independently.
workgate.bindBridge(ws);
// Same pattern for env-request: the modal pushes fulfill / cancel
// back through the bridge.
envRequests.bindBridge(ws);
