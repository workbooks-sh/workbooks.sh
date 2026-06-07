import { getToken } from "./auth.js";
import { getSessionJwt } from "./session.js";

const BASE = "https://api.brandnana.net";

/** Read the server-passed Clerk session JWT for /v1/auth/portal/* calls. */
async function clerkJwt(): Promise<string> {
  const token = getSessionJwt();
  if (!token) throw new ApiError(401, "not signed in — please sign in again");
  return token;
}

export class ApiError extends Error {
  constructor(
    public status: number,
    message: string,
  ) {
    super(message);
    this.name = "ApiError";
  }
}

async function request<T>(path: string, init: RequestInit = {}): Promise<T> {
  const token = getToken();
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    ...(init.headers as Record<string, string>),
  };
  if (token) {
    headers["Authorization"] = `Bearer ${token}`;
  }

  const res = await fetch(`${BASE}${path}`, { ...init, headers });

  if (!res.ok) {
    const text = await res.text().catch(() => res.statusText);
    throw new ApiError(res.status, text);
  }

  // 204 No Content — return undefined cast to T
  if (res.status === 204) return undefined as unknown as T;

  return res.json() as Promise<T>;
}

// ─── Auth / Keys ──────────────────────────────────────────────────────────────
// Uses /v1/auth/portal/keys with Clerk session JWT instead of bearer-from-
// localStorage (that was a chicken-and-egg pattern). The portal proves WHO
// the user is via Clerk; the API mints/lists keys against that identity.

export interface ApiKey {
  id: string;
  prefix: string;
  label: string | null;
  created_at: number;
  last_used_at: number | null;
  revoked_at: number | null;
  rate_limit_per_min: number;
  /** Only set on create — cleartext is returned exactly once. */
  cleartext?: string;
}

export async function listKeys(): Promise<ApiKey[]> {
  const jwt = await clerkJwt();
  const res = await fetch(`${BASE}/v1/auth/portal/keys`, {
    headers: { "x-clerk-session-jwt": jwt },
  });
  if (!res.ok) throw new ApiError(res.status, await res.text().catch(() => res.statusText));
  const data = (await res.json()) as { keys: ApiKey[] };
  return data.keys;
}

export async function createKey(label: string): Promise<ApiKey> {
  const jwt = await clerkJwt();
  const res = await fetch(`${BASE}/v1/auth/portal/keys`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ clerk_session_jwt: jwt, label }),
  });
  if (!res.ok) throw new ApiError(res.status, await res.text().catch(() => res.statusText));
  return (await res.json()) as ApiKey;
}

export async function rotateKey(id: string): Promise<ApiKey> {
  // Rotate = revoke old + create new with same label. The /v1/auth/portal
  // endpoint doesn't have a single "rotate" op, but the UX is identical to
  // the user: revoke + create chained.
  const existing = (await listKeys()).find((k) => k.id === id);
  await revokeKey(id);
  return createKey(existing?.label ?? "rotated");
}

export async function revokeKey(id: string): Promise<void> {
  const jwt = await clerkJwt();
  const res = await fetch(`${BASE}/v1/auth/portal/keys/${id}`, {
    method: "DELETE",
    headers: { "x-clerk-session-jwt": jwt },
  });
  if (!res.ok) throw new ApiError(res.status, await res.text().catch(() => res.statusText));
}

// ─── Connections ──────────────────────────────────────────────────────────────
export interface ConnectionStatus {
  provider: "meta" | "tiktok" | "google";
  connected: boolean;
  handle: string | null;
  account_id: string | null;
  token_state: "valid" | "expired" | "missing";
  last_refresh: string | null;
  reconnect_url: string | null;
}

export function getConnectionStatus(
  provider: string,
): Promise<ConnectionStatus> {
  return request<ConnectionStatus>(`/oauth/${provider}/status`);
}

// ─── Account ─────────────────────────────────────────────────────────────────
export interface AccountInfo {
  email: string;
  plan: string;
  calls_per_month: number;
  calls_used: number;
  dollar_cap: number;
  dollar_used: number;
}

export function getAccount(): Promise<AccountInfo> {
  return request<AccountInfo>("/account");
}

// ─── Activity ────────────────────────────────────────────────────────────────
// NOTE (wb-c4hs.2): GET /v1/activity not yet implemented on the API side.
// UI is wired; wire the server-side handler as a follow-up.

export interface Activity {
  id: string;
  ts: string;
  verb_id: string;
  source: string;
  duration_ms: number;
  cost_usd: number;
  status: "ok" | "error";
  error?: string;
}

export async function listActivity(opts: {
  limit?: number;
  cursor?: string;
}): Promise<{ items: Activity[]; next_cursor?: string }> {
  const params = new URLSearchParams();
  if (opts.limit != null) params.set("limit", String(opts.limit));
  if (opts.cursor) params.set("cursor", opts.cursor);
  const qs = params.toString() ? `?${params}` : "";
  try {
    return await request<{ items: Activity[]; next_cursor?: string }>(
      `/v1/activity${qs}`,
    );
  } catch (e) {
    console.error("[brandnana/api] listActivity:", e);
    return { items: [] };
  }
}

// ─── Spend ───────────────────────────────────────────────────────────────────
// NOTE (wb-c4hs.2): GET /v1/spend not yet implemented on the API side.

export interface SpendBucket {
  key: string;
  calls: number;
  cost_usd: number;
  avg_cost_usd: number;
}

export async function getSpend(opts: {
  from?: string;
  to?: string;
  group_by?: "day" | "provider" | "verb";
}): Promise<{ buckets: SpendBucket[]; total_usd: number }> {
  const params = new URLSearchParams();
  if (opts.from) params.set("from", opts.from);
  if (opts.to) params.set("to", opts.to);
  if (opts.group_by) params.set("group_by", opts.group_by);
  const qs = params.toString() ? `?${params}` : "";
  try {
    return await request<{ buckets: SpendBucket[]; total_usd: number }>(
      `/v1/spend${qs}`,
    );
  } catch (e) {
    console.error("[brandnana/api] getSpend:", e);
    return { buckets: [], total_usd: 0 };
  }
}

// ─── Data ────────────────────────────────────────────────────────────────────
// NOTE (wb-c4hs.2): GET /v1/data/{catalog|ads|briefs} not yet implemented on the API side.

export interface DataRow {
  id: string;
  target: string;
  started_at: string;
  duration_ms: number;
  status: "ok" | "error" | "running";
  r2_url?: string;
}

export async function listData(
  kind: "catalog" | "ads" | "briefs",
  opts: { limit?: number; cursor?: string },
): Promise<{ items: DataRow[]; next_cursor?: string }> {
  const params = new URLSearchParams();
  if (opts.limit != null) params.set("limit", String(opts.limit));
  if (opts.cursor) params.set("cursor", opts.cursor);
  const qs = params.toString() ? `?${params}` : "";
  try {
    return await request<{ items: DataRow[]; next_cursor?: string }>(
      `/v1/data/${kind}${qs}`,
    );
  } catch (e) {
    console.error("[brandnana/api] listData:", e);
    return { items: [] };
  }
}
