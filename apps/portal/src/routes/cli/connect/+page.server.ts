// /cli/connect?code=ABCD-1234
// Server-rendered approval page for the CLI device flow.
//
// load(): looks up the code on the API to confirm it's valid + show client info.
// approve action: POSTs Clerk JWT + code to api.brandnana.net/v1/auth/cli/approve.

import { redirect } from "@sveltejs/kit";
import type { Actions, PageServerLoad } from "./$types";
import { env } from "$env/dynamic/private";

const API_BASE = "https://api.brandnana.net";

interface Lookup {
  user_code: string;
  status: string;
  client_info: Record<string, unknown> | null;
  expires_at: number;
}

export const load: PageServerLoad = async ({ url, locals }) => {
  const code = url.searchParams.get("code")?.trim().toUpperCase() ?? "";
  if (!code) {
    return { code: null, lookupError: "No code provided. The CLI should open this page with ?code=ABCD-1234.", lookup: null };
  }
  if (!locals.auth.userId) {
    redirect(303, `/app/auth/sign-in?redirect_url=${encodeURIComponent(`/cli/connect?code=${code}`)}`);
  }

  try {
    const r = await fetch(`${API_BASE}/v1/auth/cli/lookup?code=${encodeURIComponent(code)}`);
    if (!r.ok) {
      const text = await r.text().catch(() => "");
      return { code, lookupError: `Lookup failed (${r.status}): ${text.slice(0, 200)}`, lookup: null };
    }
    const lookup = (await r.json()) as Lookup;
    return { code, lookupError: null, lookup };
  } catch (e) {
    return { code, lookupError: (e as Error).message, lookup: null };
  }
};

export const actions: Actions = {
  approve: async ({ request, locals }) => decide(request, locals, "approve"),
  deny: async ({ request, locals }) => decide(request, locals, "deny"),
};

async function decide(request: Request, locals: App.Locals, decision: "approve" | "deny") {
  if (!locals.auth.userId || !locals.auth.sessionToken) {
    return { ok: false, error: "Not signed in." };
  }
  const form = await request.formData();
  const code = form.get("code")?.toString().trim().toUpperCase() ?? "";
  if (!code) return { ok: false, error: "Missing code." };

  const r = await fetch(`${API_BASE}/v1/auth/cli/approve`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      clerk_session_jwt: locals.auth.sessionToken,
      user_code: code,
      decision,
    }),
  });
  const data = (await r.json().catch(() => ({}))) as { ok?: boolean; error?: string; status?: string };
  if (!r.ok) {
    return { ok: false, error: data.error ?? `HTTP ${r.status}` };
  }
  return { ok: true, decision, status: data.status };
}
