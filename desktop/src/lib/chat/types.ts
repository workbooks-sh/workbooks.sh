// wb-i38o.4 — chat surface types.
//
// The OQL agent broadcasts a small set of telemetry events on the
// per-session channel `session:<id>` (see packages/oql/elixir/oql-agent
// /lib/oql_agent/web/session_channel.ex). This module narrows the
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

export type ChatBlock = AssistantMessage | ToolCallBlock | StatusBanner | RawEventRow;
