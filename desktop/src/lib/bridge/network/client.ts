/**
 * Bridge: Network broker client — desktop ↔ control-plane.
 *
 * Phase B canonical schema. Splits cleanly by placement:
 *
 *   - LOCAL-STORE (offline): network mode (demo|live) + broker URL.
 *     These are plain client config, persisted in localStorage so the
 *     choice survives reloads without the daemon. setNetworkMode /
 *     setBrokerUrl / getNetworkMode / getBrokerUrl.
 *
 *   - NATIVE (offline): fork_upstream_status. Fork base is local
 *     per-machine state (ForkWatcher lives in the user's workspace,
 *     not the broker). The upstream-head half still needs the broker
 *     (pending) but the call is host-side native.
 *
 *   - RUNTIME (graceful-offline): every /v1/network/* broker endpoint
 *     goes through the control-plane via engineRequest (which attaches
 *     the daemon Bearer token). When the daemon is down each wrapper
 *     degrades gracefully — list endpoints return an empty/default
 *     shape and lookups return null, NEVER throwing to the UI. In demo
 *     mode the same graceful defaults apply so the design surface
 *     keeps rendering without a broker.
 *
 * Broker REST paths (/v1/network/*) are unchanged — correct as-is.
 */

import { invoke } from "@tauri-apps/api/core";
import { engineRequest, EngineApiError } from "$lib/engine-api/gen";

// ── Local-store config (offline) ──────────────────────────────────

export type NetworkMode = "demo" | "live";

const MODE_KEY = "workbooks.network.mode";
const BROKER_KEY = "workbooks.network.brokerUrl";
const DEFAULT_BROKER = "https://auth.workbooks.sh";

function readLocal(key: string): string | null {
  try {
    return typeof localStorage !== "undefined" ? localStorage.getItem(key) : null;
  } catch {
    return null;
  }
}

function writeLocal(key: string, value: string): void {
  try {
    if (typeof localStorage !== "undefined") localStorage.setItem(key, value);
  } catch {
    // Non-fatal: in-memory copy below still holds for this session.
  }
}

let mode: NetworkMode = readLocal(MODE_KEY) === "live" ? "live" : "demo";
let baseUrl = (readLocal(BROKER_KEY) ?? DEFAULT_BROKER).replace(/\/$/, "");

export function setNetworkMode(m: NetworkMode): void {
  mode = m;
  writeLocal(MODE_KEY, m);
}

export function setBrokerUrl(url: string): void {
  baseUrl = url.replace(/\/$/, "");
  writeLocal(BROKER_KEY, baseUrl);
}

export function getNetworkMode(): NetworkMode {
  return mode;
}

/** The broker base URL the share module also reads, so both client
 *  layers stay in sync after setBrokerUrl(). */
export function getBrokerUrl(): string {
  return baseUrl;
}

// ── Graceful runtime helper ───────────────────────────────────────

/** Run a runtime broker call, returning `fallback` whenever the
 *  daemon is offline (EngineApiError "daemon_down") or we're in demo
 *  mode. Never throws to the UI for transport/offline reasons —
 *  callers get the empty/default shape and keep rendering. Genuine
 *  upstream errors (4xx/5xx with a body) are also swallowed to the
 *  fallback so the network surface degrades softly; surface-level
 *  error UI is layered separately. */
async function runtime<T>(
  path: string,
  opts: Parameters<typeof engineRequest>[1],
  fallback: T,
): Promise<T> {
  if (mode === "demo") return fallback;
  try {
    return await engineRequest<T>(path, opts);
  } catch (e) {
    if (e instanceof EngineApiError) return fallback;
    return fallback;
  }
}

// ── Response types — mirror Broker's network.ts contracts ──────────

export interface BrokerIdentity {
  handle: string;
  did: string;
  display_name: string | null;
  /** WorkOS-side first+last name when the identity is WorkOS-bound.
   *  Drives the provenance badge's "verified · real name" tier. null
   *  for magic-link / legacy bindings. */
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

// ── Identity / resolve ─────────────────────────────────────────────

export async function getIdentity(): Promise<BrokerIdentity | null> {
  return runtime<BrokerIdentity | null>("/v1/network/identity", {}, null);
}

export async function resolveHandle(handle: string): Promise<BrokerIdentity | null> {
  return runtime<BrokerIdentity | null>(
    `/v1/network/resolve/${encodeURIComponent(handle)}`,
    {},
    null,
  );
}

/** Reverse: DID → identity. Used by ProvenanceBadge to surface the
 *  handle + WorkOS-verified real name for a signed workbook's issuer. */
export async function resolveDid(did: string): Promise<BrokerIdentity | null> {
  return runtime<BrokerIdentity | null>(
    `/v1/network/resolve-did/${encodeURIComponent(did)}`,
    {},
    null,
  );
}

export async function getSeeds(): Promise<SeedsResponse> {
  return runtime<SeedsResponse>("/v1/network/seeds", {}, {
    seeds: [],
    server_time: 0,
  });
}

export async function getInbox(
  opts: { since?: number } = {},
): Promise<InboxResponse> {
  return runtime<InboxResponse>(
    "/v1/network/inbox",
    { query: opts.since ? `?since=${opts.since}` : undefined },
    { pending: [], server_time: 0 },
  );
}

export async function settleShare(
  share_id: string,
  action: "accept" | "decline",
): Promise<ShareSettlement> {
  return runtime<ShareSettlement>(
    `/v1/network/shares/${encodeURIComponent(share_id)}/${action}`,
    { method: "POST" },
    { share_id, to_handle: "", accepted_at: null, declined_at: null },
  );
}

// ── Fork upstream status (native, local ForkWatcher) ──────────────

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
 *  NATIVE: the fork base is per-machine local state (ForkWatcher lives
 *  in the user's workspace and doesn't cross-sync), so this reads the
 *  Rust shell. The upstream-head half still needs the broker (pending)
 *  — the host returns whatever local advances it can compute. */
export async function listForkAdvances(): Promise<ForkUpstreamStatusResponse> {
  try {
    return await invoke<ForkUpstreamStatusResponse>("fork_upstream_status");
  } catch {
    return { advances: [], server_time: 0 };
  }
}

// ── Friends ─────────────────────────────────────────────────────────

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
  return runtime<FriendsResponse>(
    "/v1/network/friends",
    { query: opts.status?.length ? `?status=${opts.status.join(",")}` : undefined },
    { friends: [], server_time: 0 },
  );
}

export async function requestFriend(
  handle: string,
): Promise<{ outcome: FriendRequestOutcome; handle: string }> {
  return runtime<{ outcome: FriendRequestOutcome; handle: string }>(
    "/v1/network/friends",
    { method: "POST", body: { handle } },
    { outcome: "requested", handle },
  );
}

export async function settleFriendRequest(
  handle: string,
  action: "accept" | "decline",
): Promise<FriendView> {
  return runtime<FriendView>(
    `/v1/network/friends/${encodeURIComponent(handle)}/${action}`,
    { method: "POST" },
    { handle, status: "declined", source: "manual", created_at: 0, updated_at: 0 },
  );
}

export async function blockHandle(handle: string): Promise<FriendView> {
  return runtime<FriendView>(
    `/v1/network/friends/${encodeURIComponent(handle)}/block`,
    { method: "POST" },
    { handle, status: "blocked", source: "manual", created_at: 0, updated_at: 0 },
  );
}

export async function unfriend(handle: string): Promise<void> {
  await runtime<unknown>(
    `/v1/network/friends/${encodeURIComponent(handle)}`,
    { method: "DELETE" },
    null,
  );
}

// ── Groups ──────────────────────────────────────────────────────────

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
  return runtime<GroupsResponse>("/v1/network/groups", {}, {
    groups: [],
    server_time: 0,
  });
}

export async function getGroup(id: string): Promise<GroupDetailView> {
  return runtime<GroupDetailView>(
    `/v1/network/groups/${encodeURIComponent(id)}`,
    {},
    {
      id,
      name: "",
      owner_handle: "",
      visibility: "private",
      created_at: 0,
      updated_at: 0,
      my_role: null,
      members: [],
    },
  );
}

export async function createGroup(args: {
  name: string;
  visibility?: GroupVisibility;
}): Promise<GroupDetailView> {
  return runtime<GroupDetailView>(
    "/v1/network/groups",
    { method: "POST", body: args },
    {
      id: "",
      name: args.name,
      owner_handle: "",
      visibility: args.visibility ?? "private",
      created_at: 0,
      updated_at: 0,
      my_role: "owner",
      members: [],
    },
  );
}

export async function updateGroup(
  id: string,
  args: { name?: string; visibility?: GroupVisibility },
): Promise<GroupView> {
  return runtime<GroupView>(
    `/v1/network/groups/${encodeURIComponent(id)}`,
    { method: "PATCH", body: args },
    {
      id,
      name: args.name ?? "",
      owner_handle: "",
      visibility: args.visibility ?? "private",
      created_at: 0,
      updated_at: 0,
      my_role: null,
    },
  );
}

export async function deleteGroup(id: string): Promise<void> {
  await runtime<unknown>(
    `/v1/network/groups/${encodeURIComponent(id)}`,
    { method: "DELETE" },
    null,
  );
}

export async function addGroupMember(
  id: string,
  handle: string,
  role?: "member" | "admin",
): Promise<{ handle: string; role: GroupRole; joined_at: number }> {
  return runtime<{ handle: string; role: GroupRole; joined_at: number }>(
    `/v1/network/groups/${encodeURIComponent(id)}/members`,
    { method: "POST", body: { handle, role } },
    { handle, role: role ?? "member", joined_at: 0 },
  );
}

export async function removeGroupMember(id: string, handle: string): Promise<void> {
  await runtime<unknown>(
    `/v1/network/groups/${encodeURIComponent(id)}/members/${encodeURIComponent(handle)}`,
    { method: "DELETE" },
    null,
  );
}

// ── Subscriptions ───────────────────────────────────────────────────

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
  return runtime<SubscriptionsResponse>("/v1/network/subscriptions", {}, {
    subscriptions: [],
    server_time: 0,
  });
}

export async function subscribeToRid(rid: string): Promise<SubscriptionView> {
  return runtime<SubscriptionView>(
    "/v1/network/subscriptions",
    { method: "POST", body: { rid } },
    { rid, subscribed_at: 0, last_seen_commit: null, last_seen_at: null },
  );
}

export async function unsubscribeFromRid(rid: string): Promise<void> {
  await runtime<unknown>(
    `/v1/network/subscriptions/${encodeURIComponent(rid)}`,
    { method: "DELETE" },
    null,
  );
}

export async function ackSubscription(
  rid: string,
  head_commit: string,
): Promise<SubscriptionView> {
  return runtime<SubscriptionView>(
    `/v1/network/subscriptions/${encodeURIComponent(rid)}/ack`,
    { method: "POST", body: { head_commit } },
    { rid, subscribed_at: 0, last_seen_commit: head_commit, last_seen_at: 0 },
  );
}
