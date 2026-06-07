import type { Actions, PageServerLoad } from "./$types";
import { fail, redirect } from "@sveltejs/kit";

/** Live URL runner — workbooks.sh/r/<slug>.
 *
 *  Two-step server-side fetch against the broker:
 *    1. GET /v1/rooms/<slug>            → metadata (workbook_id, access_mode, enabled)
 *    2. GET /v1/rooms/<slug>/blob       → the workbook .html bytes
 *
 *  This is a +page.server.ts (NOT a universal +page.ts) for two
 *  reasons: (a) the .html is large (3–15 MB) and shipping it twice
 *  (once for SSR, once for hydration) is wasted bytes; (b) cross-
 *  origin browser fetches to the broker would need CORS — server
 *  fetches don't. The Pages worker and broker are co-located at the
 *  edge, so the extra hop is cheap.
 *
 *  Access modes:
 *    - link:    just fetch the blob
 *    - password: slice 4 will branch to a password gate page here
 *    - network:  slice ? will branch to a Workbooks-auth gate */
import { env } from "$env/dynamic/public";

const BROKER_URL = env.PUBLIC_BROKER_URL ?? "https://auth.workbooks.sh";

/** Per-slug unlock cookie name (slice 4). Stored on the viewer's
 *  origin, not the broker's — the viewer's server load reads it and
 *  forwards as X-Room-Token to the broker. */
function unlockCookieName(slug: string): string {
  return `wb_room_${slug}`;
}

/** Per-viewer comment identity cookie (slice 5). Lives on the viewer
 *  origin, scoped to the slug. Stores { name, color } as JSON. Set on
 *  first comment, reused on every subsequent. */
function identityCookieName(slug: string): string {
  return `wb_room_id_${slug}`;
}

const COLOR_PALETTE = [
  "#ff7a59", "#3b82f6", "#10b981", "#f59e0b", "#8b5cf6",
  "#ec4899", "#06b6d4", "#84cc16", "#f97316", "#a855f7",
];

function pickColor(name: string): string {
  let h = 0;
  for (let i = 0; i < name.length; i++) h = (h * 31 + name.charCodeAt(i)) | 0;
  return COLOR_PALETTE[Math.abs(h) % COLOR_PALETTE.length];
}

export interface ViewerIdentity {
  name: string;
  color: string;
}

export interface RunnerCommentView {
  id: string;
  room_slug: string;
  anchor_kind: "cell" | "region" | "page";
  anchor_target: string | null;
  anchor_resolved: boolean;
  body: string;
  author_name: string;
  author_color: string;
  created_at: number;
  resolved_at: number | null;
}

export type RunnerLoad =
  | {
      kind: "ok";
      slug: string;
      workbook_id: string;
      html: string;
      identity: ViewerIdentity | null;
      unlockToken: string | null;
      comments: RunnerCommentView[];
    }
  | { kind: "disabled"; slug: string }
  | { kind: "not_found"; slug: string }
  | { kind: "password_required"; slug: string }
  | { kind: "network_auth_required"; slug: string }
  | { kind: "live_url_unsupported"; slug: string }
  | { kind: "desktop_only_share"; slug: string }
  | { kind: "error"; slug: string; message: string };

export const load: PageServerLoad = async ({ params, fetch, cookies }): Promise<RunnerLoad> => {
  const slug = params.slug;

  // Step 1: metadata. The room may exist but be disabled, or the
  // workbook behind it might be revoked — both surface as 410 on
  // the broker side.
  let metaRes: Response;
  try {
    metaRes = await fetch(`${BROKER_URL}/v1/rooms/${encodeURIComponent(slug)}`);
  } catch (err) {
    return {
      kind: "error",
      slug,
      message: `Broker unreachable: ${err instanceof Error ? err.message : String(err)}`,
    };
  }

  if (metaRes.status === 404) return { kind: "not_found", slug };
  if (metaRes.status === 410) return { kind: "disabled", slug };
  if (!metaRes.ok) {
    return {
      kind: "error",
      slug,
      message: `Broker returned ${metaRes.status} on metadata fetch.`,
    };
  }

  const meta = (await metaRes.json()) as {
    room: { slug: string; workbook_id: string; access_mode: string; enabled: boolean };
  };

  // Step 2: gate. Network mode is still unwired; password mode reads
  // the per-slug unlock cookie and forwards it to the broker.
  if (meta.room.access_mode === "network") {
    return { kind: "network_auth_required", slug };
  }

  let blobHeaders: Record<string, string> = {};
  if (meta.room.access_mode === "password") {
    const token = cookies.get(unlockCookieName(slug));
    if (!token) return { kind: "password_required", slug };
    blobHeaders["X-Room-Token"] = token;
  }

  // Step 3: blob fetch.
  let blobRes: Response;
  try {
    blobRes = await fetch(`${BROKER_URL}/v1/rooms/${encodeURIComponent(slug)}/blob`, {
      headers: blobHeaders,
    });
  } catch (err) {
    return {
      kind: "error",
      slug,
      message: `Broker unreachable on blob fetch: ${err instanceof Error ? err.message : String(err)}`,
    };
  }

  // A 401 on a password-mode room means the cookie was stale —
  // surface the gate again so the recipient can re-enter the password.
  if (blobRes.status === 401 && meta.room.access_mode === "password") {
    cookies.delete(unlockCookieName(slug), { path: `/r/${slug}` });
    return { kind: "password_required", slug };
  }
  if (blobRes.status === 410) return { kind: "disabled", slug };
  if (blobRes.status === 404) return { kind: "not_found", slug };
  // wb-unzn.25 P2 — tier-gated refusals from the broker. 501 = live-url
  // (hosted runtime not yet provisioned, tracking wb-hqtg Phase F);
  // 403 = desktop-tier workbook that requires Workbooks Desktop on the
  // recipient side and refuses anonymous service.
  if (blobRes.status === 501) {
    const body = await blobRes.json().catch(() => null) as { error?: string } | null;
    if (body?.error === "live_url_unsupported") {
      return { kind: "live_url_unsupported", slug };
    }
  }
  if (blobRes.status === 403) {
    const body = await blobRes.json().catch(() => null) as { error?: string } | null;
    if (body?.error === "desktop_only_share") {
      return { kind: "desktop_only_share", slug };
    }
  }
  if (!blobRes.ok) {
    return {
      kind: "error",
      slug,
      message: `Broker returned ${blobRes.status} on blob fetch.`,
    };
  }

  const html = await blobRes.text();

  // Read the persistent viewer identity (slice 5). Best-effort —
  // bogus JSON just means we render the name prompt.
  let identity: ViewerIdentity | null = null;
  const idCookie = cookies.get(identityCookieName(slug));
  if (idCookie) {
    try {
      const v = JSON.parse(idCookie);
      if (typeof v?.name === "string" && typeof v?.color === "string") {
        identity = { name: v.name, color: v.color };
      }
    } catch { /* fall through */ }
  }

  // The unlock token (when present) is what the presence WebSocket
  // needs as ?t=<token> on the upgrade. We pass it down to the
  // client so PresenceClient can include it. The cookie itself is
  // httpOnly — the WS handshake is browser-side so the cookie
  // won't auto-attach to a cross-origin WS connect, but exposing
  // the token to the page script is safe: it's already scoped to
  // the slug, single-use is not a property of the token, and the
  // client already had it (they set the cookie). For link mode this
  // is null.
  const unlockToken = meta.room.access_mode === "password"
    ? cookies.get(unlockCookieName(slug)) ?? null
    : null;

  // Fetch comments alongside the workbook so the runner can render
  // cell-anchored pins on first paint. Carries the unlock token for
  // password rooms; failures here are non-fatal — an empty thread
  // shouldn't block the iframe.
  let comments: RunnerCommentView[] = [];
  try {
    const cHeaders: Record<string, string> = {};
    if (unlockToken) cHeaders["X-Room-Token"] = unlockToken;
    const cr = await fetch(
      `${BROKER_URL}/v1/rooms/${encodeURIComponent(slug)}/comments`,
      { headers: cHeaders },
    );
    if (cr.ok) {
      const body = (await cr.json()) as { comments: RunnerCommentView[] };
      comments = body.comments ?? [];
    }
  } catch { /* leave empty */ }

  return {
    kind: "ok",
    slug,
    workbook_id: meta.room.workbook_id,
    html,
    identity,
    unlockToken,
    comments,
  };
};

/** Password gate submit. POSTs the password to the broker's unlock
 *  endpoint, stashes the returned token in a per-slug cookie on the
 *  viewer's origin, then redirects to the same route so the load
 *  function runs again with the cookie in scope. */
export const actions: Actions = {
  unlock: async ({ params, request, fetch, cookies }) => {
    const slug = params.slug;
    if (!slug) return fail(400, { error: "bad_slug" });

    const form = await request.formData();
    const password = form.get("password");
    if (typeof password !== "string" || password.length === 0) {
      return fail(400, { error: "password_required" });
    }

    const r = await fetch(`${BROKER_URL}/v1/rooms/${encodeURIComponent(slug)}/unlock`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ password }),
    });

    if (r.status === 401) return fail(401, { error: "wrong_password" });
    if (r.status === 410) return fail(410, { error: "disabled" });
    if (r.status === 404) return fail(404, { error: "unknown_room" });
    if (!r.ok) return fail(r.status, { error: "broker_error" });

    const body = (await r.json()) as { token: string; expires_in: number };
    cookies.set(unlockCookieName(slug), body.token, {
      path: `/r/${slug}`,
      httpOnly: true,
      sameSite: "lax",
      secure: true,
      maxAge: body.expires_in,
    });

    // 303 → next request re-runs load() with the cookie set; load
    // forwards it to broker as X-Room-Token and the iframe renders.
    throw redirect(303, `/r/${slug}`);
  },

  /** Post a comment (slice 5). All comments from the viewer route are
   *  page-anchored — cell/region anchors need a workbook-runtime
   *  postMessage protocol that lands in slice 5.1. */
  comment: async ({ params, request, fetch, cookies }) => {
    const slug = params.slug;
    if (!slug) return fail(400, { error: "bad_slug" });

    const form = await request.formData();
    const name = String(form.get("name") ?? "").trim();
    const body = String(form.get("body") ?? "").trim();
    if (name.length === 0 || name.length > 64) {
      return fail(400, { error: "bad_name" });
    }
    if (body.length === 0 || body.length > 8 * 1024) {
      return fail(400, { error: "bad_body" });
    }

    // Anchor — `cell` requires a non-empty anchor_target; `page` is
    // the default and ignores any target. The cell-anchor observer
    // emits these values via hidden inputs when the composer was
    // opened by clicking a cell.
    const anchorKindRaw = String(form.get("anchor_kind") ?? "page");
    const anchorTargetRaw = form.get("anchor_target");
    const anchor_kind = anchorKindRaw === "cell" ? "cell" : "page";
    const anchor_target = anchor_kind === "cell"
      ? (typeof anchorTargetRaw === "string" ? anchorTargetRaw : "").trim()
      : null;
    if (anchor_kind === "cell" && (!anchor_target || anchor_target.length === 0)) {
      return fail(400, { error: "anchor_target_required" });
    }

    const color = pickColor(name);

    // Carry the unlock token for password-mode rooms.
    const headers: Record<string, string> = { "Content-Type": "application/json" };
    const unlock = cookies.get(unlockCookieName(slug));
    if (unlock) headers["X-Room-Token"] = unlock;

    const r = await fetch(`${BROKER_URL}/v1/rooms/${encodeURIComponent(slug)}/comments`, {
      method: "POST",
      headers,
      body: JSON.stringify({
        anchor_kind,
        anchor_target,
        body,
        author_name: name,
        author_color: color,
      }),
    });
    if (r.status === 401) return fail(401, { error: "password_required" });
    if (!r.ok) {
      const text = await r.text().catch(() => "");
      return fail(r.status, { error: text || "broker_error" });
    }

    // Remember this viewer's identity for the next comment on this
    // slug. 30-day life is enough — anonymous; not security-sensitive.
    cookies.set(identityCookieName(slug), JSON.stringify({ name, color }), {
      path: `/r/${slug}`,
      httpOnly: true,
      sameSite: "lax",
      secure: true,
      maxAge: 30 * 24 * 3600,
    });

    return { commentPosted: true };
  },
};
