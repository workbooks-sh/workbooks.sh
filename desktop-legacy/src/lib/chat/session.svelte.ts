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
// (mirrors how Studio's "new turn" flow works against the OQL runtime
// today — every prompt instantiates a fresh agent).

import { ws, type BridgeEvent } from "$lib/bridge/ws.svelte";
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
} from "./types";

interface RawEntry {
  event: BridgeEvent;
}

class ChatSessionStore {
  session = $state<SessionInfo | null>(null);
  blocks = $state<ChatBlock[]>([]);
  /** the prompt the user typed for this session (cards above the agent reply) */
  userPrompt = $state<string | null>(null);
  /** non-fatal error (e.g. failed to POST /api/run); cleared on next send */
  sendError = $state<string | null>(null);
  sending = $state(false);

  #unsub: (() => void) | null = null;
  #raw: RawEntry[] = [];
  #initStarted = false;

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
    // Reset block list — one session per panel for v1.
    this.#raw = [];
    this.blocks = [];
    this.userPrompt = t;
    this.session = null;
    try {
      const id = await ws.sendUserInput(t, {
        agentSlug: opts.agentSlug,
        skills: opts.skills,
      });
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
      const slug = opts.agentSlug ?? agents.selected ?? "workhorse";
      agentSessions.record(slug, id, t);
      this.#reproject();
    } catch (e) {
      this.sendError = e instanceof Error ? e.message : String(e);
      this.userPrompt = null;
    } finally {
      this.sending = false;
    }
  }

  /** Send the channel-level `cancel` event for the current session. */
  cancel() {
    const id = this.session?.id;
    if (!id) return;
    ws.cancelSession(id);
  }

  // ── internals ──

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
   *  is O(events) per ingest which is fine for v1 (oql sessions emit
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
