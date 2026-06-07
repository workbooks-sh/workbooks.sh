// Server-side keys list — uses the user's session JWT to call the API
// directly. No client-side JWT plumbing needed.

import { fail, redirect } from "@sveltejs/kit";
import type { Actions, PageServerLoad } from "./$types";

const API_BASE = "https://api.brandnana.net";

interface ApiKey {
  id: string;
  prefix: string;
  label: string | null;
  created_at: number;
  last_used_at: number | null;
  revoked_at: number | null;
  rate_limit_per_min: number;
  cleartext?: string;
}

async function listKeys(jwt: string): Promise<ApiKey[]> {
  const r = await fetch(`${API_BASE}/v1/auth/portal/keys`, {
    headers: { "x-clerk-session-jwt": jwt },
  });
  if (!r.ok) throw new Error(`list ${r.status}: ${await r.text().catch(() => "")}`);
  const data = (await r.json()) as { keys: ApiKey[] };
  return data.keys;
}

export const load: PageServerLoad = async ({ locals }) => {
  if (!locals.auth.userId || !locals.auth.sessionToken) {
    return { keys: [] as ApiKey[], loadError: "Not signed in." };
  }
  try {
    const keys = await listKeys(locals.auth.sessionToken);
    return { keys, loadError: null };
  } catch (e) {
    return { keys: [] as ApiKey[], loadError: (e as Error).message };
  }
};

export const actions: Actions = {
  create: async ({ request, locals }) => {
    if (!locals.auth.sessionToken) return fail(401, { error: "Not signed in." });
    const form = await request.formData();
    const label = form.get("label")?.toString().trim().slice(0, 80) ?? "";
    const r = await fetch(`${API_BASE}/v1/auth/portal/keys`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ clerk_session_jwt: locals.auth.sessionToken, label: label || "portal" }),
    });
    if (!r.ok) {
      return fail(r.status, { error: `Create failed: ${await r.text().catch(() => r.statusText)}` });
    }
    const created = (await r.json()) as ApiKey;
    return { created };
  },

  revoke: async ({ request, locals }) => {
    if (!locals.auth.sessionToken) return fail(401, { error: "Not signed in." });
    const form = await request.formData();
    const id = form.get("id")?.toString().trim();
    if (!id) return fail(400, { error: "Missing key id." });
    const r = await fetch(`${API_BASE}/v1/auth/portal/keys/${encodeURIComponent(id)}`, {
      method: "DELETE",
      headers: { "x-clerk-session-jwt": locals.auth.sessionToken },
    });
    if (!r.ok) {
      return fail(r.status, { error: `Revoke failed: ${await r.text().catch(() => r.statusText)}` });
    }
    return { revoked: id };
  },
};
