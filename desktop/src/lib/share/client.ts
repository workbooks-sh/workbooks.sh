/**
 * Broker client for the Live URLs share surface (wb-v9ys.3).
 *
 * Thin typed wrappers around the broker's room + workbook endpoints.
 * Reuses the network client's base URL + auth posture so the two
 * layers stay in lock-step on setBrokerUrl() / setNetworkMode().
 *
 * Demo mode: throws DemoModeError so the Share drawer can surface the
 * "Sign in to share" CTA instead of attempting a real request.
 *
 * Tracker: bd show wb-v9ys.3
 */

import {
  DemoModeError,
  getBrokerUrl,
  getNetworkMode,
} from "$lib/network/client";
import { asError } from "$lib/_http";

// ── Wire types — mirror services/broker/worker/src/routes/rooms.ts ──

export type RoomAccessMode = "link" | "password" | "network";

export interface RoomView {
  slug: string;
  workbook_id: string;
  access_mode: RoomAccessMode;
  enabled: boolean;
  created_at: number;
  updated_at: number;
  /** Present on owner-facing endpoints; absent on the public GET. */
  has_password?: boolean;
}

export interface RegisterWorkbookResult {
  policy_hash: string;
}

// ── Helpers ────────────────────────────────────────────────────────

function requireLive(): void {
  if (getNetworkMode() === "demo") throw new DemoModeError();
}

// ── Endpoints ──────────────────────────────────────────────────────

/** Register a fresh workbook. The room layer above does the actual
 *  access gating, so the policy can stay permissive — a room with
 *  enabled=false is the broker's real "off switch". */
export async function registerWorkbook(args: {
  workbook_id: string;
}): Promise<RegisterWorkbookResult> {
  requireLive();
  // Minimal policy: allow everyone, single default view, all-views.
  // The room is the gate; the workbook's own visibility is incidental.
  const policy = {
    allow: [{ email: "*" }],
    views: { default: { allow: ["*"] } },
  };
  const r = await fetch(`${getBrokerUrl()}/v1/workbooks`, {
    method: "POST",
    credentials: "include",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ workbook_id: args.workbook_id, policy }),
  });
  if (!r.ok) throw await asError(r);
  return r.json();
}

/** Upload the workbook .html bytes. Replaces any prior artifact for
 *  the same workbook_id — this is also the "release a new version"
 *  verb. */
export async function putArtifact(args: {
  workbook_id: string;
  html: string;
}): Promise<void> {
  requireLive();
  const r = await fetch(
    `${getBrokerUrl()}/v1/workbooks/${encodeURIComponent(args.workbook_id)}/artifact`,
    {
      method: "PUT",
      credentials: "include",
      headers: { "Content-Type": "text/html" },
      body: args.html,
    },
  );
  if (!r.ok) throw await asError(r);
}

export async function createRoom(args: {
  workbook_id: string;
  access_mode?: RoomAccessMode;
  /** Required when access_mode = 'password'. Min 4 chars; broker
   *  echoes that constraint in the error envelope on bad input. */
  password?: string;
}): Promise<RoomView> {
  requireLive();
  const r = await fetch(
    `${getBrokerUrl()}/v1/workbooks/${encodeURIComponent(args.workbook_id)}/rooms`,
    {
      method: "POST",
      credentials: "include",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        access_mode: args.access_mode ?? "link",
        password: args.password,
      }),
    },
  );
  if (!r.ok) throw await asError(r);
  const body = await r.json() as { room: RoomView };
  return body.room;
}

export async function listRoomsForWorkbook(workbook_id: string): Promise<RoomView[]> {
  requireLive();
  const r = await fetch(
    `${getBrokerUrl()}/v1/workbooks/${encodeURIComponent(workbook_id)}/rooms`,
    { credentials: "include" },
  );
  if (!r.ok) throw await asError(r);
  const body = await r.json() as { rooms: RoomView[] };
  return body.rooms;
}

export async function patchRoom(args: {
  slug: string;
  enabled?: boolean;
  access_mode?: RoomAccessMode;
  /** Set or rotate the password. Required when transitioning
   *  access_mode into 'password' for the first time. */
  password?: string;
}): Promise<RoomView> {
  requireLive();
  const r = await fetch(
    `${getBrokerUrl()}/v1/rooms/${encodeURIComponent(args.slug)}`,
    {
      method: "PATCH",
      credentials: "include",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        enabled: args.enabled,
        access_mode: args.access_mode,
        password: args.password,
      }),
    },
  );
  if (!r.ok) throw await asError(r);
  const body = await r.json() as { room: RoomView };
  return body.room;
}

export async function deleteRoom(slug: string): Promise<void> {
  requireLive();
  const r = await fetch(
    `${getBrokerUrl()}/v1/rooms/${encodeURIComponent(slug)}`,
    { method: "DELETE", credentials: "include" },
  );
  if (!r.ok && r.status !== 404) throw await asError(r);
}

// ── Comments (wb-v9ys.5) ────────────────────────────────────────────

export type CommentAnchorKind = "cell" | "region" | "page";

export interface CommentView {
  id: string;
  room_slug: string;
  anchor_kind: CommentAnchorKind;
  anchor_target: string | null;
  anchor_resolved: boolean;
  body: string;
  author_name: string;
  author_color: string;
  created_at: number;
  resolved_at: number | null;
}

/** Owner-side comment fetch. Goes through the same gate the public
 *  read uses — for link-mode rooms that's a no-op; for password mode
 *  the owner's broker session bypasses the gate (the route checks
 *  the room owner_sub, not the unlock cookie, for owner ops elsewhere
 *  — but GET /comments uses readGateRoom which requires the unlock
 *  cookie for password-mode anonymous reads). The owner side fetches
 *  it via the desktop's broker session which the broker treats as
 *  authenticated and skips the cookie check.
 *
 *  Implementation note: for v1, the desktop reads the same public
 *  endpoint as anonymous viewers. Owner-bypass on the readGateRoom
 *  helper is tracked in the rooms route. */
export async function listComments(slug: string): Promise<CommentView[]> {
  requireLive();
  const r = await fetch(
    `${getBrokerUrl()}/v1/rooms/${encodeURIComponent(slug)}/comments`,
    { credentials: "include" },
  );
  if (!r.ok) throw await asError(r);
  const body = await r.json() as { comments: CommentView[] };
  return body.comments;
}

export async function setCommentResolved(args: {
  slug: string;
  id: string;
  resolved: boolean;
}): Promise<CommentView> {
  requireLive();
  const r = await fetch(
    `${getBrokerUrl()}/v1/rooms/${encodeURIComponent(args.slug)}/comments/${encodeURIComponent(args.id)}`,
    {
      method: "PATCH",
      credentials: "include",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ resolved: args.resolved }),
    },
  );
  if (!r.ok) throw await asError(r);
  const body = await r.json() as { comment: CommentView };
  return body.comment;
}

// ── Tier limits (wb-v9ys.7) ────────────────────────────────────────

export interface LiveUrlLimitsView {
  tier: "free" | "solo" | "team" | "enterprise";
  /** null = uncapped. */
  max_enabled_rooms: number | null;
  can_password: boolean;
  can_presence: boolean;
  /** null = uncapped. */
  bandwidth_bytes_per_month: number | null;
}

export interface TierReadback {
  limits: LiveUrlLimitsView;
  enabled_rooms_used: number;
}

export async function fetchTierLimits(): Promise<TierReadback> {
  requireLive();
  const r = await fetch(`${getBrokerUrl()}/v1/rooms/_limits`, {
    credentials: "include",
  });
  if (!r.ok) throw await asError(r);
  return r.json() as Promise<TierReadback>;
}

export async function deleteCommentRow(args: { slug: string; id: string }): Promise<void> {
  requireLive();
  const r = await fetch(
    `${getBrokerUrl()}/v1/rooms/${encodeURIComponent(args.slug)}/comments/${encodeURIComponent(args.id)}`,
    { method: "DELETE", credentials: "include" },
  );
  if (!r.ok && r.status !== 404) throw await asError(r);
}

// ── Slug → live URL ────────────────────────────────────────────────

/** Build the recipient-facing URL the user copies and shares. The
 *  runner route is at the viewer's domain (workbooks.sh), not the
 *  broker — keep this resolution in one place so subdomain Pro
 *  routing in slice 7 only edits this function. */
export function liveUrlFor(slug: string): string {
  // Same-origin convention: the viewer lives on workbooks.sh (Pages),
  // not auth.workbooks.sh (broker). When the desktop runs in dev mode
  // and the broker is localhost, fall back to a localhost viewer
  // assumption (port 5174 matches apps/viewer's dev config).
  const broker = getBrokerUrl();
  if (broker.startsWith("http://localhost") || broker.startsWith("http://127.")) {
    return `http://localhost:5174/r/${slug}`;
  }
  return `https://workbooks.sh/r/${slug}`;
}
