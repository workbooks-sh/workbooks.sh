// Server-side Clerk Frontend API client. Bypasses both the Account Portal
// (broken for us — accounts.brandnana.net is unverified) AND Clerk JS in
// the browser (gets blocked by ad-blockers).
//
// FAPI accepts password sign-ins, sign-ups, and ticket exchanges directly.
// It returns a `client` object whose `last_active_session_id` + `sessions[]`
// give us a Clerk-signed JWT we can put in the __session cookie. Once that
// cookie is set on app.brandnana.net, hooks.server.ts (via @clerk/backend's
// authenticateRequest) treats the user as signed in normally.

interface FapiSession {
  id: string;
  last_active_token?: { jwt: string };
  status: string;
  user?: { id: string; primary_email_address_id?: string };
}

interface FapiClient {
  id: string;
  sessions?: FapiSession[];
  last_active_session_id?: string;
  sign_in?: { status: string; created_session_id?: string };
  sign_up?: { status: string; created_session_id?: string };
}

export interface FapiResponse {
  client?: FapiClient;
  response?: any;
  errors?: Array<{ message: string; long_message?: string; code?: string; meta?: any }>;
}

function host(publishableKey: string): string {
  const b64 = publishableKey.replace(/^pk_(test|live)_/, "");
  const padded = b64.padEnd(b64.length + ((4 - (b64.length % 4)) % 4), "=");
  return atob(padded).replace(/\$+$/, "");
}

async function fapiPost(
  publishableKey: string,
  path: string,
  body: Record<string, string>,
  extraHeaders: Record<string, string> = {},
): Promise<FapiResponse> {
  const url = `https://${host(publishableKey)}${path}?_clerk_js_version=5.0.0`;
  const res = await fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/x-www-form-urlencoded",
      "Origin": "https://app.brandnana.net",
      "User-Agent": "brandnana-portal/1.0 (Cloudflare Worker)",
      ...extraHeaders,
    },
    body: new URLSearchParams(body).toString(),
  });
  const json = (await res.json().catch(() => ({}))) as FapiResponse;
  if (!res.ok) {
    const err = json.errors?.[0];
    const msg = err?.long_message ?? err?.message ?? `FAPI ${res.status}`;
    const error = new Error(msg);
    (error as any).errors = json.errors;
    (error as any).status = res.status;
    throw error;
  }
  return json;
}

/** Sign-in with email + password. Returns a JWT on success, or throws. */
export async function fapiSignInWithPassword(
  publishableKey: string,
  identifier: string,
  password: string,
): Promise<{ jwt: string; sessionId: string; userId: string }> {
  const data = await fapiPost(publishableKey, "/v1/client/sign_ins", {
    identifier,
    strategy: "password",
    password,
  });
  return extractActiveSession(data, "sign-in");
}

/** Sign-up with email + password (no separate email verification step). */
export async function fapiSignUpWithPassword(
  publishableKey: string,
  emailAddress: string,
  password: string,
  firstName?: string,
): Promise<{ jwt: string; sessionId: string; userId: string }> {
  const body: Record<string, string> = {
    email_address: emailAddress,
    password,
  };
  if (firstName) body.first_name = firstName;
  const data = await fapiPost(publishableKey, "/v1/client/sign_ups", body);
  return extractActiveSession(data, "sign-up");
}

/** Exchange a server-minted sign-in ticket for a live session JWT. */
export async function fapiExchangeTicket(
  publishableKey: string,
  ticket: string,
): Promise<{ jwt: string; sessionId: string; userId: string }> {
  const data = await fapiPost(publishableKey, "/v1/client/sign_ins", {
    strategy: "ticket",
    ticket,
  });
  return extractActiveSession(data, "ticket");
}

function extractActiveSession(
  data: FapiResponse,
  source: string,
): { jwt: string; sessionId: string; userId: string } {
  const client = data.client;
  const sessions = client?.sessions ?? [];
  const activeId = client?.last_active_session_id ?? client?.sign_in?.created_session_id ?? client?.sign_up?.created_session_id;
  const active = sessions.find((s) => s.id === activeId) ?? sessions.find((s) => s.status === "active");
  if (!active || !active.last_active_token?.jwt) {
    const err = new Error(`Clerk ${source} did not return an active session.`);
    (err as any).fapi = data;
    throw err;
  }
  return {
    jwt: active.last_active_token.jwt,
    sessionId: active.id,
    userId: active.user?.id ?? "",
  };
}
