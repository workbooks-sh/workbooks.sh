// A live-voice transcript bubble — either a spoken message (you/waldo) or a
// bash/tool call Waldo ran mid-conversation. Shared store state so the voice
// transcript survives WaldoPanel remounting into a tab.
export type VoiceBubble =
  | { kind: "msg"; id: number; who: "you" | "waldo"; text: string }
  | {
      kind: "tool";
      id: number;
      callId: string;
      command: string;
      status: "running" | "ok" | "error";
      output: string | null;
    };

// wb-i38o.4 — chat surface types.
//
// The OQL agent broadcasts a small set of telemetry events on the
// per-session channel `session:<id>` (see runtime/host
// /lib/agent/web/session_channel.ex). This module narrows the
// inbound `BridgeEvent` stream into typed shapes the chat UI can render.
//
// Inbound channel events (today):
//   session_started        — { session_id, started_at, agent }
//   llm_turn_start         — { session_id, measurements, metadata: { message_count, … } }
//   llm_turn_stop          — { session_id, measurements,
//                              metadata: { status, stop_reason, content, content_size,
//                                          tokens_in, tokens_out, tool_call_count } }
//   tool_call_start        — { session_id, measurements,
//                              metadata: { tool_name, tool_call_id, args } }
//   tool_call_stop         — { session_id, measurements,
//                              metadata: { tool_name, tool_call_id, status, result_size } }
//   session_persisted      — telemetry envelope
//   lease_lost             — telemetry envelope
//   session_completed      — { session_id, finished_at, result }
//   session_failed         — { session_id, finished_at, reason }
//   session_cancelled      — { session_id, finished_at }

export type SessionStatus =
  | "pending"
  | "running"
  | "completed"
  | "failed"
  | "cancelled";

export interface SessionInfo {
  id: string;
  status: SessionStatus;
  startedAt: number;
  finishedAt: number | null;
  /** human-readable detail to surface on terminal-state banners */
  detail: string | null;
  /** the user's initial prompt for this session (kept for re-render after reload) */
  prompt: string;
  /** wb-lueb — attachments surfaced in the chat header (briefs from
   *  the planning wizard for now; future: images, files, links). */
  attachments?: SessionAttachment[];
}

/** One attached document referenced by a chat session. Today the
 *  only kind is `brief` (planning-wizard output); the shape stays
 *  general so future kinds can join without a type explosion. */
export interface SessionAttachment {
  kind: "brief";
  /** Absolute filesystem path. */
  path: string;
  /** Wizard id that produced this brief (e.g. "create-board"). Used
   *  to choose an icon + label in the header chip. */
  wizardId: string;
  /** Display name shown on the chip — usually the wizard's title. */
  label: string;
}

export interface AssistantMessage {
  kind: "message";
  key: string;
  /** llm provider label if surfaceable from payload */
  label: string;
  /** finalized text from llm_turn_stop.content. Empty until stop arrives. */
  text: string;
  /** true while only llm_turn_start has been seen */
  pending: boolean;
  /** true if llm_turn_stop reported status=error */
  error: boolean;
  errorMessage: string | null;
  ts: number;
}

export interface ToolCallBlock {
  kind: "tool";
  key: string;
  toolName: string;
  args: unknown;
  /** "ok" | "error" | undefined while running */
  status: "ok" | "error" | null;
  resultSize: number | null;
  pending: boolean;
  ts: number;
}

export interface StatusBanner {
  kind: "status";
  key: string;
  level: "info" | "ok" | "warn" | "error";
  label: string;
  detail: string | null;
  ts: number;
}

export interface RawEventRow {
  kind: "raw";
  key: string;
  name: string;
  ts: number;
}

/** The component-toolkit EXEC shape: the agent produced a component
 *  artifact (an HTML/workbook file) the user opens as a tab and keeps
 *  iterating on with the agent.
 *
 *  Emitted as a `component_artifact` telemetry event on the session
 *  channel with payload `{ path, title, kind, action }`. `action` is
 *  "created" the first time the artifact is written and "updated" on
 *  every subsequent edit of the same path — so the card can say
 *  "Updated" rather than re-announce a new artifact. */
export interface ArtifactBlock {
  kind: "artifact";
  key: string;
  /** Absolute (or mock) path the artifact was written to — opens as a tab. */
  path: string;
  /** Display title for the card + tab. */
  title: string;
  /** "created" | "updated" — drives the card verb. */
  action: "created" | "updated";
  ts: number;
}

export type ChatBlock =
  | AssistantMessage
  | ToolCallBlock
  | StatusBanner
  | RawEventRow
  | ArtifactBlock;
