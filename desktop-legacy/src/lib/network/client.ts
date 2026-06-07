/**
 * Broker client for the Network surface. Typed wrappers around the
 * `/v1/network/*` endpoints; cookies-included for session auth.
 *
 * Two modes:
 *   - "demo" — never hits the network; consumers fall back to fixture
 *     data so the design surface keeps rendering without a broker.
 *   - "live" — fetches Broker; surfaces typed responses or throws.
 *
 * Default is "demo" until the Tauri ↔ Broker session bridge lands
 * (wb-u2o0.2.6 follow-up). Flip via `setNetworkMode("live")` from
 * the desktop bootstrap once cookies are available.
 */

import { asError } from "$lib/_http";

export type NetworkMode = "demo" | "live";
let mode: NetworkMode = "demo";

let baseUrl = "https://auth.workbooks.sh";

export function setNetworkMode(m: NetworkMode): void {
  mode = m;
}

export function setBrokerUrl(url: string): void {
  baseUrl = url.replace(/\/$/, "");
}

export function getNetworkMode(): NetworkMode {
  return mode;
}

/** The broker base URL the share module also reads, so both client
 *  layers stay in sync after setBrokerUrl(). */
export function getBrokerUrl(): string {
  return baseUrl;
}

// ── Response types — mirror Broker's network.ts contracts ──────────

export interface BrokerIdentity {
  handle: string;
  did: string;
  display_name: string | null;
  /** WorkOS-side first+last name when the identity is WorkOS-bound.
   *  Drives the provenance badge's "verified · real name" tier
   *  (wb-u2o0.5.4). null for magic-link / legacy bindings. */
  workos_display_name: string | null;
  created_at: number;
  updated_at: number;
}

export interface SeedNode {
  peer_id: string;
  address: string;
  region: string;
}

export interface SeedsResponse {
  seeds: SeedNode[];
  server_time: number;
}

export type ShareArtifactKind = "workbook" | "agent" | "plugin" | "skill";
export type SharePosture = "public" | "friends" | "group" | "private";

export interface InboxShareView {
  id: string;
  from_handle: string;
  from_did: string | null;
  rid: string;
  artifact_kind: ShareArtifactKind;
  message: string | null;
  posture: SharePosture;
  created_at: number;
  delivered_at: number | null;
}

export interface InboxResponse {
  pending: InboxShareView[];
  server_time: number;
}

export interface ShareSettlement {
  share_id: string;
  to_handle: string;
  accepted_at: number | null;
  declined_at: number | null;
}

// ── Errors ─────────────────────────────────────────────────────────

export class NetworkClientError extends Error {
  constructor(
    message: string,
    public readonly status?: number,
    public readonly body?: unknown,
  ) {
    super(message);
    this.name = "NetworkClientError";
  }
}

/** Thrown when called in `demo` mode — callers should catch + fall back. */
export class DemoModeError extends Error {
  constructor() {
    super("network client in demo mode");
    this.name = "DemoModeError";
  }
}

// ── Endpoint wrappers ──────────────────────────────────────────────

export async function getIdentity(): Promise<BrokerIdentity | null> {
  if (mode === "demo") throw new DemoModeError();
  const r = await fetch(`${baseUrl}/v1/network/identity`, {
    credentials: "include",
  });
  if (r.status === 404) return null;
  if (r.status === 401) throw new NetworkClientError("auth_required", 401);
  if (!r.ok) throw await asError(r);
  return r.json();
}

export async function resolveHandle(handle: string): Promise<BrokerIdentity | null> {
  if (mode === "demo") throw new DemoModeError();
  const r = await fetch(
    `${baseUrl}/v1/network/resolve/${encodeURIComponent(handle)}`,
  );
  if (r.status === 404) return null;
  if (!r.ok) throw await asError(r);
  return r.json();
}

// ── Fork upstream status (wb-u2o0.6.3) ─────────────────────────────

export interface ForkAdvance {
  fork_rid: string;
  upstream_rid: string;
  fork_base: string;
  upstream_head: string;
}

export interface ForkUpstreamStatusResponse {
  advances: ForkAdvance[];
  server_time: number;
}

/** Forks whose upstream has moved past their last-rebased base.
 *  Drives the "Pull upstream changes" indicator in PreviewPane.
 *
 *  Sourced from Workhorse's local ForkWatcher (per-machine state, not
 *  Broker — forks live in the user's local workspace and don't
 *  cross-sync). The HTTP path /v1/network/forks/upstream-status hits
 *  the oql-agent internal API rather than the Broker.
 *
 *  Demo mode: throws DemoModeError; caller falls back to fixture data. */
export async function listForkAdvances(): Promise<ForkUpstreamStatusResponse> {
  if (mode === "demo") throw new DemoModeError();
  const r = await fetch(`${baseUrl}/v1/network/forks/upstream-status`, {
    credentials: "include",
  });
  if (!r.ok) throw await asError(r);
  return r.json();
}

/** Reverse: DID → identity. Used by ProvenanceBadge to surface the
 *  handle + WorkOS-verified real name for a signed workbook's issuer.
 *  wb-u2o0.5.4. */
export async function resolveDid(did: string): Promise<BrokerIdentity | null> {
  if (mode === "demo") throw new DemoModeError();
  const r = await fetch(
    `${baseUrl}/v1/network/resolve-did/${encodeURIComponent(did)}`,
  );
  if (r.status === 404) return null;
  if (!r.ok) throw await asError(r);
  return r.json();
}

export async function getSeeds(): Promise<SeedsResponse> {
  if (mode === "demo") throw new DemoModeError();
  const r = await fetch(`${baseUrl}/v1/network/seeds`);
  if (!r.ok) throw await asError(r);
  return r.json();
}

export async function getInbox(opts: { since?: number } = {}): Promise<InboxResponse> {
  if (mode === "demo") throw new DemoModeError();
  const q = opts.since ? `?since=${opts.since}` : "";
  const r = await fetch(`${baseUrl}/v1/network/inbox${q}`, {
    credentials: "include",
  });
  if (!r.ok) throw await asError(r);
  return r.json();
}

export async function settleShare(
  share_id: string,
  action: "accept" | "decline",
): Promise<ShareSettlement> {
  if (mode === "demo") throw new DemoModeError();
  const r = await fetch(
    `${baseUrl}/v1/network/shares/${encodeURIComponent(share_id)}/${action}`,
    { method: "POST", credentials: "include" },
  );
  if (!r.ok) throw await asError(r);
  return r.json();
}

// ── Friends (wb-u2o0.3.1) ──────────────────────────────────────────

export type FriendshipStatus =
  | "pending_sent"
  | "pending_received"
  | "accepted"
  | "declined"
  | "blocked";

export interface FriendView {
  handle: string;
  status: FriendshipStatus;
  source: "manual" | "github" | "atproto";
  created_at: number;
  updated_at: number;
}

export interface FriendsResponse {
  friends: FriendView[];
  server_time: number;
}

export type FriendRequestOutcome =
  | "requested"
  | "auto_accepted"
  | "already_friends"
  | "blocked_by_target";

export async function listFriends(
  opts: { status?: FriendshipStatus[] } = {},
): Promise<FriendsResponse> {
  if (mode === "demo") throw new DemoModeError();
  const q = opts.status?.length ? `?status=${opts.status.join(",")}` : "";
  const r = await fetch(`${baseUrl}/v1/network/friends${q}`, {
    credentials: "include",
  });
  if (!r.ok) throw await asError(r);
  return r.json();
}

export async function requestFriend(handle: string): Promise<{ outcome: FriendRequestOutcome; handle: string }> {
  if (mode === "demo") throw new DemoModeError();
  const r = await fetch(`${baseUrl}/v1/network/friends`, {
    method: "POST",
    credentials: "include",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ handle }),
  });
  if (!r.ok) throw await asError(r);
  return r.json();
}

export async function settleFriendRequest(
  handle: string,
  action: "accept" | "decline",
): Promise<FriendView> {
  if (mode === "demo") throw new DemoModeError();
  const r = await fetch(
    `${baseUrl}/v1/network/friends/${encodeURIComponent(handle)}/${action}`,
    { method: "POST", credentials: "include" },
  );
  if (!r.ok) throw await asError(r);
  return r.json();
}

export async function blockHandle(handle: string): Promise<FriendView> {
  if (mode === "demo") throw new DemoModeError();
  const r = await fetch(
    `${baseUrl}/v1/network/friends/${encodeURIComponent(handle)}/block`,
    { method: "POST", credentials: "include" },
  );
  if (!r.ok) throw await asError(r);
  return r.json();
}

export async function unfriend(handle: string): Promise<void> {
  if (mode === "demo") throw new DemoModeError();
  const r = await fetch(
    `${baseUrl}/v1/network/friends/${encodeURIComponent(handle)}`,
    { method: "DELETE", credentials: "include" },
  );
  if (!r.ok) throw await asError(r);
}

// ── Groups (wb-u2o0.3.2) ───────────────────────────────────────────

export type GroupVisibility = "private" | "invite-only";
export type GroupRole = "owner" | "admin" | "member";

export interface GroupView {
  id: string;
  name: string;
  owner_handle: string;
  visibility: GroupVisibility;
  created_at: number;
  updated_at: number;
  my_role: GroupRole | null;
}

export interface GroupDetailView extends GroupView {
  members: { handle: string; role: GroupRole; joined_at: number }[];
}

export interface GroupsResponse {
  groups: GroupView[];
  server_time: number;
}

export async function listGroups(): Promise<GroupsResponse> {
  if (mode === "demo") throw new DemoModeError();
  const r = await fetch(`${baseUrl}/v1/network/groups`, {
    credentials: "include",
  });
  if (!r.ok) throw await asError(r);
  return r.json();
}

export async function getGroup(id: string): Promise<GroupDetailView> {
  if (mode === "demo") throw new DemoModeError();
  const r = await fetch(`${baseUrl}/v1/network/groups/${encodeURIComponent(id)}`, {
    credentials: "include",
  });
  if (!r.ok) throw await asError(r);
  return r.json();
}

export async function createGroup(args: {
  name: string;
  visibility?: GroupVisibility;
}): Promise<GroupDetailView> {
  if (mode === "demo") throw new DemoModeError();
  const r = await fetch(`${baseUrl}/v1/network/groups`, {
    method: "POST",
    credentials: "include",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(args),
  });
  if (!r.ok) throw await asError(r);
  return r.json();
}

export async function updateGroup(
  id: string,
  args: { name?: string; visibility?: GroupVisibility },
): Promise<GroupView> {
  if (mode === "demo") throw new DemoModeError();
  const r = await fetch(`${baseUrl}/v1/network/groups/${encodeURIComponent(id)}`, {
    method: "PATCH",
    credentials: "include",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(args),
  });
  if (!r.ok) throw await asError(r);
  return r.json();
}

export async function deleteGroup(id: string): Promise<void> {
  if (mode === "demo") throw new DemoModeError();
  const r = await fetch(`${baseUrl}/v1/network/groups/${encodeURIComponent(id)}`, {
    method: "DELETE",
    credentials: "include",
  });
  if (!r.ok) throw await asError(r);
}

export async function addGroupMember(
  id: string,
  handle: string,
  role?: "member" | "admin",
): Promise<{ handle: string; role: GroupRole; joined_at: number }> {
  if (mode === "demo") throw new DemoModeError();
  const r = await fetch(`${baseUrl}/v1/network/groups/${encodeURIComponent(id)}/members`, {
    method: "POST",
    credentials: "include",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ handle, role }),
  });
  if (!r.ok) throw await asError(r);
  return r.json();
}

export async function removeGroupMember(id: string, handle: string): Promise<void> {
  if (mode === "demo") throw new DemoModeError();
  const r = await fetch(
    `${baseUrl}/v1/network/groups/${encodeURIComponent(id)}/members/${encodeURIComponent(handle)}`,
    { method: "DELETE", credentials: "include" },
  );
  if (!r.ok) throw await asError(r);
}

// ── Subscriptions (wb-u2o0.4.1) ────────────────────────────────────

export interface SubscriptionView {
  rid: string;
  subscribed_at: number;
  last_seen_commit: string | null;
  last_seen_at: number | null;
}

export interface SubscriptionsResponse {
  subscriptions: SubscriptionView[];
  server_time: number;
}

export async function listSubscriptions(): Promise<SubscriptionsResponse> {
  if (mode === "demo") throw new DemoModeError();
  const r = await fetch(`${baseUrl}/v1/network/subscriptions`, {
    credentials: "include",
  });
  if (!r.ok) throw await asError(r);
  return r.json();
}

export async function subscribeToRid(rid: string): Promise<SubscriptionView> {
  if (mode === "demo") throw new DemoModeError();
  const r = await fetch(`${baseUrl}/v1/network/subscriptions`, {
    method: "POST",
    credentials: "include",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ rid }),
  });
  if (!r.ok) throw await asError(r);
  return r.json();
}

export async function unsubscribeFromRid(rid: string): Promise<void> {
  if (mode === "demo") throw new DemoModeError();
  const r = await fetch(
    `${baseUrl}/v1/network/subscriptions/${encodeURIComponent(rid)}`,
    { method: "DELETE", credentials: "include" },
  );
  if (!r.ok) throw await asError(r);
}

export async function ackSubscription(
  rid: string,
  head_commit: string,
): Promise<SubscriptionView> {
  if (mode === "demo") throw new DemoModeError();
  const r = await fetch(
    `${baseUrl}/v1/network/subscriptions/${encodeURIComponent(rid)}/ack`,
    {
      method: "POST",
      credentials: "include",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ head_commit }),
    },
  );
  if (!r.ok) throw await asError(r);
  return r.json();
}
