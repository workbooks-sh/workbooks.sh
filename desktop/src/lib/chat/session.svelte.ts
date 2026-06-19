// wb-i38o.4 — single-session chat store.
//
// Owns one in-flight session at a time. Subscribes to the bridge's
// event stream, filters to the current session topic, and projects the
// raw channel events into a `ChatBlock[]` the UI renders top-to-bottom.
//
// The Phoenix channel for `session:<id>` is joined inside
// `ws.sendUserInput()` once the agent assigns an id, so the store
// itself doesn't need to manage subscriptions.
//
// One active session per chat panel is the v1 contract. Sending while
// a session is already running is allowed but starts a *new* session
// (mirrors how Studio's "new turn" flow works against the runtime
// today — every prompt instantiates a fresh agent).

import { ws, type BridgeEvent } from "$lib/bridge/ws.svelte";
import { rcp } from "$lib/rcp";
import { sidecar } from "$lib/bridge/sidecar.svelte";
import { agents } from "$lib/bridge/agents.svelte";
import { agentSessions } from "./agent_sessions.svelte";
import type {
  ChatBlock,
  SessionInfo,
  AssistantMessage,
  ToolCallBlock,
  StatusBanner,
  RawEventRow,
  ArtifactBlock,
  VoiceBubble,
} from "./types";
import { componentArtifacts } from "./artifacts.svelte";
import { mockMode, runMockComponentAgent } from "./mockAgent.svelte";

interface RawEntry {
  event: BridgeEvent;
}

class ChatSessionStore {
  session = $state<SessionInfo | null>(null);
  blocks = $state<ChatBlock[]>([]);
  /** the prompt the user typed for this session (cards above the agent reply) */
  userPrompt = $state<string | null>(null);
  /** Time-ordered echoes of the user's own messages this conversation. Lives
   *  on the store (not the panel) so the transcript survives the panel
   *  remounting — e.g. when the live chat is opened as a tab and the user
   *  switches away and comes back (Feature 2). */
  userEchoes = $state<{ text: string; ts: number }[]>([]);
  /** Push a user message echo. Called by every send surface (dock + tab). */
  pushEcho(text: string) {
    this.userEchoes = [...this.userEchoes, { text, ts: Date.now() }];
  }
  /** Clear the conversation transcript (new chat). */
  clearTranscript() {
    this.userEchoes = [];
    this.blocks = [];
    this.session = null;
  }

  /** Live-voice transcript. Lives on the store (not the panel) so a voice
   *  conversation started in the dock is visible — and stays visible — in the
   *  returnable chat tab, surviving WaldoPanel remounts (Feature 2/3). */
  voiceBubbles = $state<VoiceBubble[]>([]);
  voiceError = $state<string | null>(null);
  #voiceSeq = 0;

  voiceReset() {
    this.voiceBubbles = [];
    this.voiceError = null;
  }
  /** Append a spoken chunk, merging into the trailing bubble of the same side. */
  voiceAppend(who: "you" | "waldo", chunk: string) {
    const last = this.voiceBubbles[this.voiceBubbles.length - 1];
    if (last && last.kind === "msg" && last.who === who) {
      this.voiceBubbles = [
        ...this.voiceBubbles.slice(0, -1),
        { ...last, text: last.text + chunk },
      ];
    } else {
      this.voiceBubbles = [
        ...this.voiceBubbles,
        { kind: "msg", id: ++this.#voiceSeq, who, text: chunk },
      ];
    }
  }
  voicePushTool(callId: string, command: string) {
    this.voiceBubbles = [
      ...this.voiceBubbles,
      { kind: "tool", id: ++this.#voiceSeq, callId, command, status: "running", output: null },
    ];
  }
  voiceCompleteTool(callId: string, output: string) {
    this.voiceBubbles = this.voiceBubbles.map((b) => {
      if (b.kind !== "tool" || b.callId !== callId) return b;
      const status: "ok" | "error" = output.startsWith("exit=0") ? "ok" : "error";
      return { ...b, status, output };
    });
  }

  /** Start a live Waldo voice session wired to THIS store's voice transcript.
   *  The single home for "start voice" so every entry point (the home
   *  composer's "+" menu, the Waldo panel) drives the same conversation that
   *  the panel renders — voice lives in the panel (work demo TASK 3). Idempotent
   *  when a session is already present. */
  async startVoice(): Promise<void> {
    const { inworldLive } = await import("$lib/live/inworld.svelte");
    if (inworldLive.present) return;
    this.voiceReset();
    await inworldLive.start({
      onUserTranscript: (t) => this.voiceAppend("you", t),
      onAgentTranscript: (t) => this.voiceAppend("waldo", t),
      onCode: (task, code) => {
        // The code lane output — surface it as a tool block in the transcript
        // so it's visible, not spoken.
        const id = crypto.randomUUID();
        this.voicePushTool(id, `write_code: ${task}`);
        this.voiceCompleteTool(id, code);
      },
      onError: (msg) => {
        this.voiceError = msg;
      },
    });
  }
  /** non-fatal error (e.g. failed to POST /api/run); cleared on next send */
  sendError = $state<string | null>(null);
  sending = $state(false);

  #unsub: (() => void) | null = null;
  #raw: RawEntry[] = [];
  #initStarted = false;
  /** Aborts the in-flight unary /api/run request when the user cancels. */
  #runAbort: AbortController | null = null;
  /** Set when the user cancels; an aborted rcp.request throws, and this
   *  flag lets the catch treat that throw as a clean cancel, not an error. */
  #cancelled = false;

  /** A unary nexus run may legitimately take minutes; the server clamps to
   *  ≤300s. We give the client request a little headroom past that. */
  #RUN_TIMEOUT_MS = 305_000;

  init() {
    if (this.#initStarted) return;
    this.#initStarted = true;
    this.#unsub = ws.subscribe((e) => this.#ingest(e));
  }

  destroy() {
    this.#unsub?.();
    this.#unsub = null;
    this.#initStarted = false;
  }

  /** Compose a new session. Sends the prompt via the bridge, captures
   *  the returned session id, resets the block list.
   *
   *  Opts:
   *  - `agentSlug` — override the active picker selection (wb-lueb:
   *    wizard follow-on uses the wizard's configured executor agent).
   *  - `attachments` — initial attachments surfaced in the chat
   *    header (wb-lueb: the brief chip).
   */
  async send(
    text: string,
    opts: {
      agentSlug?: string | null;
      attachments?: import("./types").SessionAttachment[];
      /** wb-8285 — skill slugs attached via the @-picker. Server
       *  prepends each SKILL.md body to the system prompt before
       *  running the agent. */
      skills?: string[];
    } = {},
  ): Promise<void> {
    const t = text.trim();
    if (!t) return;
    if (sidecar.status.state !== "ready") {
      this.sendError = "Sidecar not ready yet.";
      return;
    }
    this.sending = true;
    this.sendError = null;
    this.#cancelled = false;
    // Reset block list — one session per panel for v1.
    this.#raw = [];
    this.blocks = [];
    this.userPrompt = t;
    this.session = null;
    try {
      // Browser preview: no runtime/Phoenix. Drive the scripted mock agent
      // (component-toolkit artifact flow) through the same event pipeline so
      // the chat surface behaves identically to a live run.
      if (mockMode()) {
        const id = `mock-${Date.now()}`;
        this.session = {
          id,
          status: "pending",
          startedAt: Date.now(),
          finishedAt: null,
          detail: null,
          prompt: t,
          attachments: opts.attachments ?? [],
        };
        this.#reproject();
        void runMockComponentAgent(id, t);
        return;
      }
      // Unary nexus run: a single RCP call to /api/run returns the final
      // answer. We mint the session id client-side, then bridge the result
      // into the renderer by pushing synthetic BridgeEvents onto #raw — the
      // exact same path #ingest feeds — so #reproject renders an assistant
      // message (or an error message) with no special-case render path.
      const id = crypto.randomUUID();
      this.session = {
        id,
        status: "pending",
        startedAt: Date.now(),
        finishedAt: null,
        detail: null,
        prompt: t,
        attachments: opts.attachments ?? [],
      };
      // Record into the per-agent history (localStorage-backed).
      // Pin the slug at send time — switching agents mid-conversation
      // shouldn't retroactively re-tag prior sessions.
      const slug = opts.agentSlug ?? agents.selected ?? "waldo";
      agentSessions.record(slug, id, t);
      this.#reproject();

      this.#runAbort = new AbortController();
      const res = await rcp.request<{
        ok: boolean;
        answer?: string;
        error?: string;
      }>("/api/run", {
        method: "POST",
        body: { task: t, system: undefined, timeout_ms: 300_000 },
        timeoutMs: this.#RUN_TIMEOUT_MS,
        signal: this.#runAbort.signal,
      });

      // session_started banner, then a finalized assistant message
      // synthesized from the unary result, then session_completed.
      this.#pushSynthetic(id, "session_started", {});
      if (res.ok) {
        this.#pushSynthetic(id, "llm_turn_stop", {
          metadata: { content: res.answer ?? "", status: "ok" },
        });
      } else {
        this.#pushSynthetic(id, "llm_turn_stop", {
          metadata: {
            content: res.error ?? "run failed",
            status: "error",
            error: res.error,
          },
        });
      }
      this.#pushSynthetic(id, "session_completed", {});
      if (this.session) this.session.status = res.ok ? "completed" : "failed";
      this.#reproject();
    } catch (e) {
      // A user cancel aborts the in-flight request, which throws — treat
      // that as a clean cancel (cancel() already rendered the block), not
      // an error to surface.
      if (!this.#cancelled) {
        this.sendError = e instanceof Error ? e.message : String(e);
        this.userPrompt = null;
      }
    } finally {
      this.sending = false;
    }
  }

  /** Cancel the in-flight unary run: abort the request (the catch treats
   *  the resulting throw as a clean cancel) and render a cancelled block. */
  cancel() {
    const id = this.session?.id;
    if (!id) return;
    this.#cancelled = true;
    this.#runAbort?.abort();
    this.#pushSynthetic(id, "session_cancelled", {});
    if (this.session) this.session.status = "cancelled";
    this.#reproject();
  }

  // ── internals ──

  /** Build a synthetic BridgeEvent for the current session topic and push it
   *  onto #raw — the same buffer #ingest feeds — so the unary /api/run result
   *  renders through the unchanged #reproject path. */
  #pushSynthetic(id: string, name: string, payload: unknown) {
    const now = Date.now();
    const event: BridgeEvent = {
      name,
      payload,
      topic: `session:${id}`,
      sessionId: id,
      ts: now,
      receivedAt: now,
    };
    this.#raw.push({ event });
  }

  #ingest(e: BridgeEvent) {
    // Only consume events on our session's topic. Bridge-level events
    // (bridge:connected, bridge:tx) are ignored by the chat surface —
    // the sidecar card surfaces those.
    const id = this.session?.id;
    if (!id) return;
    if (e.topic !== `session:${id}`) return;
    this.#raw.push({ event: e });
    this.#reproject();
  }

  /** Walk the captured raw entries and rebuild the block list. This
   *  is O(events) per ingest which is fine for v1 (agent sessions emit
   *  on the order of dozens of events). When that breaks down,
   *  switch to incremental append + a tool-call index. */
  #reproject() {
    if (!this.session) {
      this.blocks = [];
      return;
    }
    const sess = { ...this.session };
    const blocks: ChatBlock[] = [];
    const toolByCallId = new Map<string, ToolCallBlock>();

    for (const { event } of this.#raw) {
      const payload = (event.payload ?? {}) as Record<string, unknown>;
      const metadata =
        (payload.metadata as Record<string, unknown> | undefined) ?? null;

      switch (event.name) {
        case "session_started": {
          sess.status = "running";
          sess.startedAt = event.receivedAt;
          agentSessions.updateStatus(sess.id, "running");
          const agent = payload.agent as Record<string, unknown> | undefined;
          const label =
            (agent && typeof agent.name === "string" && agent.name) ||
            `session ${shortId(sess.id)} started`;
          blocks.push(banner("info", label, null, event));
          break;
        }
        case "llm_turn_start": {
          const label = providerLabel(metadata) ?? "Assistant";
          const msg: AssistantMessage = {
            kind: "message",
            key: `m-${event.receivedAt}-${blocks.length}`,
            label,
            text: "",
            pending: true,
            error: false,
            errorMessage: null,
            ts: event.receivedAt,
          };
          blocks.push(msg);
          break;
        }
        case "llm_delta": {
          // Streamed token chunk — append to the in-progress assistant message
          // so the reply renders as it generates. The authoritative full text
          // arrives at llm_turn_stop and reconciles (replaces) the accumulation.
          const target = findLastMessage(blocks, (m) => m.pending);
          const chunk = (metadata?.content as string | undefined) ?? "";
          if (target && chunk) target.text += chunk;
          break;
        }
        case "llm_turn_stop": {
          // Match the most-recent pending assistant message; finalize it.
          const target = findLastMessage(blocks, (m) => m.pending);
          const status = (metadata?.status as string | undefined) ?? "ok";
          const content =
            (metadata?.content as string | undefined) ??
            (metadata?.error as string | undefined) ??
            "";
          if (target) {
            target.pending = false;
            target.text = content;
            target.error = status === "error";
            target.errorMessage =
              target.error && typeof metadata?.error !== "undefined"
                ? String(metadata.error)
                : null;
          } else {
            // No prior start observed — synthesize a finalized message.
            blocks.push({
              kind: "message",
              key: `m-${event.receivedAt}-${blocks.length}`,
              label: providerLabel(metadata) ?? "Assistant",
              text: content,
              pending: false,
              error: status === "error",
              errorMessage: null,
              ts: event.receivedAt,
            });
          }
          break;
        }
        case "tool_call_start": {
          const id =
            (metadata?.tool_call_id as string | undefined) ??
            `tc-${event.receivedAt}-${blocks.length}`;
          const tb: ToolCallBlock = {
            kind: "tool",
            key: id,
            toolName:
              (metadata?.tool_name as string | undefined) ?? "tool",
            args: metadata?.args ?? null,
            status: null,
            resultSize: null,
            pending: true,
            ts: event.receivedAt,
          };
          toolByCallId.set(id, tb);
          blocks.push(tb);
          break;
        }
        case "tool_call_stop": {
          const id = metadata?.tool_call_id as string | undefined;
          const existing = id ? toolByCallId.get(id) : undefined;
          if (existing) {
            existing.pending = false;
            existing.status =
              (metadata?.status as string | undefined) === "error"
                ? "error"
                : "ok";
            existing.resultSize =
              (metadata?.result_size as number | undefined) ?? null;
          } else {
            // Out-of-order or missing start — append a finalized card.
            const synth: ToolCallBlock = {
              kind: "tool",
              key: id ?? `tc-${event.receivedAt}-${blocks.length}`,
              toolName:
                (metadata?.tool_name as string | undefined) ?? "tool",
              args: null,
              status:
                (metadata?.status as string | undefined) === "error"
                  ? "error"
                  : "ok",
              resultSize:
                (metadata?.result_size as number | undefined) ?? null,
              pending: false,
              ts: event.receivedAt,
            };
            blocks.push(synth);
          }
          break;
        }
        case "component_artifact": {
          // The component-toolkit EXEC shape produced an artifact. Surface
          // an opener card and auto-open it as a tab so the user lands on the
          // component to keep iterating with the agent. Reproject runs on
          // every ingest, so the auto-open is idempotent (the store tracks
          // which artifact keys have been opened this session).
          const path = (payload.path as string | undefined) ?? "";
          if (!path) break;
          const title =
            (payload.title as string | undefined) ??
            (path.split("/").pop() ?? "Component");
          const action =
            (payload.action as string | undefined) === "updated"
              ? "updated"
              : "created";
          const block: ArtifactBlock = {
            kind: "artifact",
            key: `artifact-${path}-${event.receivedAt}`,
            path,
            title,
            action,
            ts: event.receivedAt,
          };
          blocks.push(block);
          // Open the artifact as a tab (once per event), and on an update
          // reload an already-open tab so the new revision shows. Both are
          // idempotent — reproject re-walks every event on each ingest.
          componentArtifacts.handle(block.key, path, action);
          break;
        }
        case "session_completed": {
          sess.status = "completed";
          sess.finishedAt = event.receivedAt;
          agentSessions.updateStatus(sess.id, "completed");
          blocks.push(banner("ok", "Session complete", null, event));
          break;
        }
        case "session_failed": {
          sess.status = "failed";
          sess.finishedAt = event.receivedAt;
          sess.detail = (payload.reason as string | undefined) ?? null;
          agentSessions.updateStatus(
            sess.id,
            "failed",
            (payload.reason as string | undefined) ?? null,
          );
          blocks.push(
            banner(
              "error",
              "Session failed",
              (payload.reason as string | undefined) ?? null,
              event,
            ),
          );
          break;
        }
        case "session_cancelled": {
          sess.status = "cancelled";
          sess.finishedAt = event.receivedAt;
          agentSessions.updateStatus(sess.id, "cancelled");
          blocks.push(banner("warn", "Session cancelled", null, event));
          break;
        }
        case "session_persisted":
        case "lease_lost":
          blocks.push(raw(event));
          break;
        default:
          // Unmodeled event — surface it as a raw row so it's obvious
          // when the agent emits something the UI doesn't render yet.
          blocks.push(raw(event));
          break;
      }
    }

    this.session = sess;
    this.blocks = blocks;
  }
}

function shortId(id: string): string {
  return id.length > 12 ? id.slice(0, 8) + "…" : id;
}

function providerLabel(
  metadata: Record<string, unknown> | null,
): string | null {
  if (!metadata) return null;
  const p = metadata.provider as string | undefined;
  const m = metadata.model as string | undefined;
  if (p && m) return `${p} · ${m}`;
  return p ?? m ?? null;
}

function findLastMessage(
  blocks: ChatBlock[],
  predicate: (m: AssistantMessage) => boolean,
): AssistantMessage | null {
  for (let i = blocks.length - 1; i >= 0; i--) {
    const b = blocks[i];
    if (b.kind === "message" && predicate(b)) return b;
  }
  return null;
}

function banner(
  level: StatusBanner["level"],
  label: string,
  detail: string | null,
  event: BridgeEvent,
): StatusBanner {
  return {
    kind: "status",
    key: `${event.name}-${event.receivedAt}`,
    level,
    label,
    detail,
    ts: event.receivedAt,
  };
}

function raw(event: BridgeEvent): RawEventRow {
  return {
    kind: "raw",
    key: `${event.name}-${event.receivedAt}`,
    name: event.name,
    ts: event.receivedAt,
  };
}

export const chatSession = new ChatSessionStore();
