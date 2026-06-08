// Cloudflare Worker edge-gate (sealed-bundle part c). A Worker is edge COMPUTE
// (unlike Pages, which is a static CDN that ships the whole app) — so it can hold
// secrets, check auth, and decide byte-by-byte what leaves. Here it is the
// RCP key-release broker at the edge:
//
//   • serves the PUBLIC shell from static assets (env.ASSETS)
//   • GET  /.well-known/workbooks-runtime  → the RCP capabilities handshake
//   • POST /rcp/key/:keyId                 → release a WRAPPED content key, gated
//
// CRITICAL: the Worker stores only WRAPPED keys (KeyWrap, part a) in KV — never
// plaintext. A breach of the edge leaks ciphertext + wrapped keys, not content;
// only the recipient's did private key can unwrap. The Worker enforces the
// posture (mirror of Workbooks.Access.enforce), then hands back the wrapped blob.
//
// Deploy: wrangler with [[kv_namespaces]] KEYS + an ASSETS binding for the shell.
// `verify` (bearer → identity) is injected so this stays testable + IDP-agnostic;
// production wires JWKS verification (WebCrypto) or a call to the runtime.

export type Posture = "public" | "gated_data" | "gated_route";
export interface Identity {
  user_id: string;
  tenant_id?: string;
}

// JS port of Workbooks.Access.enforce/3 — kept in lockstep with host/access.ex.
export function enforce(
  posture: Posture,
  demand: "shell" | "data" | "full",
  identity: Identity | null,
): "allow" | { deny: "auth_required" } {
  const authed = !!identity && identity.user_id !== "dev" && identity.user_id !== "";
  if (posture === "public") return "allow";
  if (posture === "gated_data") return demand === "shell" || authed ? "allow" : { deny: "auth_required" };
  // gated_route
  return authed ? "allow" : { deny: "auth_required" };
}

// The §4 error envelope.
function envelope(code: string, message: string, status: number, retryable = false): Response {
  return new Response(JSON.stringify({ error: { code, message, retryable } }), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export interface KeyStore {
  /** Wrapped key blob (base64) for a keyId, or null. In prod: a KV namespace. */
  get(keyId: string): Promise<{ wrapped: string; posture: Posture } | null>;
}

export interface GateDeps {
  /** Bearer → identity (or null). Injected: JWKS/WebCrypto in prod. */
  verify(bearer: string | null): Promise<Identity | null>;
  store: KeyStore;
}

/** Release a wrapped content key, gated by posture. Returns an RCP-enveloped
 *  Response: 200 {keyId, wrapped} on allow, 401 auth_required, 404 not_found. */
export async function handleKeyRelease(keyId: string, bearer: string | null, deps: GateDeps): Promise<Response> {
  const entry = await deps.store.get(keyId);
  if (!entry) return envelope("not_found", `no key ${keyId}`, 404);

  const identity = await deps.verify(bearer);
  const decision = enforce(entry.posture, "data", identity);
  if (decision !== "allow") {
    return envelope("tenant_required", "authentication required to release this key", 401);
  }
  // Hand back the WRAPPED key — the edge never sees plaintext; the recipient
  // unwraps with their did private key (KeyWrap.unwrap).
  return new Response(JSON.stringify({ keyId, wrapped: entry.wrapped }), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

const bearerOf = (req: Request): string | null => {
  const h = req.headers.get("authorization") ?? "";
  return h.startsWith("Bearer ") ? h.slice(7) : null;
};

export interface Env {
  ASSETS: { fetch(req: Request): Promise<Response> };
  KEYS: { get(k: string): Promise<string | null> };
  TENANCY?: string;
}

// Build the Worker fetch handler. `verify` injected so tests don't need JWKS.
export function makeWorker(verify: GateDeps["verify"]) {
  return {
    async fetch(req: Request, env: Env): Promise<Response> {
      const url = new URL(req.url);

      if (url.pathname === "/.well-known/workbooks-runtime") {
        return new Response(
          JSON.stringify({
            rcp: "1",
            runtime: "edge-cf",
            tenancy: env.TENANCY === "multi" ? "multi" : "single",
            auth: { rung: env.TENANCY === "multi" ? "oidc-jwt" : "trusted", issuer: null, jwks_url: null },
            transports: { http: true, ws: false },
            capabilities: ["key-release"],
          }),
          { headers: { "content-type": "application/json" } },
        );
      }

      const m = url.pathname.match(/^\/rcp\/key\/(.+)$/);
      if (m && req.method === "POST") {
        const store: KeyStore = {
          async get(keyId) {
            const raw = await env.KEYS.get(keyId);
            return raw ? JSON.parse(raw) : null;
          },
        };
        return handleKeyRelease(decodeURIComponent(m[1]), bearerOf(req), { verify, store });
      }

      // Everything else: the PUBLIC shell from static assets.
      return env.ASSETS.fetch(req);
    },
  };
}
