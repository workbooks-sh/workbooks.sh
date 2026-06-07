// Shared engine-loopback auth resolution for the brandnana CLI.
//
// SECURITY CONTRACT (TENANCY-SECURITY.md §3.5, shared across all remediation
// slices): when the engine spawns an agent session for tenant T, it mints a
// short-lived HMAC `TenantToken` for T and injects it into the agent's bash env
// as `WB_ENGINE_BEARER`. That token is the ONLY forgery-proof tenant source —
// the tenant is signed into the bearer with a server-held key, so the engine can
// bind the request to T without trusting any client-asserted body/header field.
//
// Every CLI verb that calls the engine over loopback MUST authenticate with
// `WB_ENGINE_BEARER` when present. Only when it is absent — i.e. single-mode /
// desktop, where the engine pins every request to `default_tenant` and there is
// nothing to spoof — does it fall back to the static `WB_PUBLIC_BEARER`.
//
// Do NOT send an `X-Tenant-Id` header from the CLI: in multi mode the tenant is
// carried inside the token, and a client-asserted tenant header is exactly the
// spoof channel the remediation closes (§3.2). In single mode it is ignored by
// the engine anyway (`tenancy.ex:76-77`).

/** Result of resolving the engine-loopback bearer. */
export interface EngineBearer {
  /** The bearer token value (no `Bearer ` prefix). */
  token: string;
  /**
   * Which env var supplied it. `WB_ENGINE_BEARER` is the per-session minted
   * TenantToken (multi-safe); `WB_PUBLIC_BEARER` is the static single-mode gate.
   */
  source: "WB_ENGINE_BEARER" | "WB_PUBLIC_BEARER";
}

/**
 * Resolve the bearer for an engine-loopback call.
 *
 * Precedence:
 *   1. `WB_ENGINE_BEARER` — the engine-injected per-session TenantToken. Used
 *      whenever present (multi mode and agent-session single mode alike). Carries
 *      the tenant, so the engine never has to trust a client-asserted tenant.
 *   2. `WB_PUBLIC_BEARER` — the static coarse gate. Fallback for single/desktop
 *      where no session token is injected.
 *
 * Throws when neither is set, because an unauthenticated engine call would be
 * rejected at the auth plug anyway and a clear message is more useful than a 401.
 */
export function resolveEngineBearer(env: NodeJS.ProcessEnv = process.env): EngineBearer {
  const session = env.WB_ENGINE_BEARER;
  if (session) return { token: session, source: "WB_ENGINE_BEARER" };

  const fallback = env.WB_PUBLIC_BEARER;
  if (fallback) return { token: fallback, source: "WB_PUBLIC_BEARER" };

  throw new Error(
    "no engine bearer available — set WB_ENGINE_BEARER (engine-injected per-session token) " +
      "or WB_PUBLIC_BEARER (single-mode/desktop) before calling the engine",
  );
}

/**
 * Build the loopback request headers for an engine call. Always sets
 * `Authorization` from {@link resolveEngineBearer}; deliberately omits
 * `X-Tenant-Id` (tenant travels in the token, never as a client-asserted header).
 */
export function engineAuthHeaders(
  extra: Record<string, string> = {},
  env: NodeJS.ProcessEnv = process.env,
): Record<string, string> {
  const { token } = resolveEngineBearer(env);
  return { ...extra, Authorization: `Bearer ${token}` };
}
