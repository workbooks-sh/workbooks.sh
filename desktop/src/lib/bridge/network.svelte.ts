/**
 * Bridge: Workbooks Network — desktop social/identity surface.
 *
 * Phase B canonical schema. Naming dropped the redundant `network_`
 * prefix: identity/workos/workspace_package/workbook_fork are bare
 * domain commands now.
 *
 * Placement:
 *   - NATIVE (offline): identity_*, workos_*, workspace_package,
 *     workgate_install, workbook_fork — invoke() the Rust shell.
 *   - RUNTIME (graceful-offline): publish → POST /v1/network/shares
 *     through the control-plane. When the daemon is down the
 *     engineRequest throws EngineApiError("daemon_down"); publish
 *     re-throws a typed PublishError so the share dialog can render an
 *     actionable "start the agent server" message rather than a raw
 *     transport error.
 *
 * Exported names are stable — the UI imports them by name; only the
 * bodies + internal command names changed.
 */

import { invoke } from "@tauri-apps/api/core";
import { onOpenUrl } from "@tauri-apps/plugin-deep-link";
import { engineRequest, EngineApiError } from "$lib/engine-api/gen";

// ── Types — mirror src-tauri network structs ──────────────────────

export interface IdentityView {
  did: string;
  handle: string | null;
  workos_user_id: string | null;
  public_key_b64: string;
}

export interface PublishArgs {
  workbook_path: string;
  recipients: string[];
  artifact_kind?: "workbook" | "agent" | "plugin" | "skill";
  posture?: "public" | "friends" | "group" | "private";
  message?: string | null;
  title?: string | null;
  broker_url: string;
  broker_token?: string | null;
}

export interface PublishResult {
  share_id: string;
  rid: string;
  signed_html_path: string;
}

/** Mirror of the Rust `StoredSession` — what the broker's
 *  `/v1/auth/exchange` returns plus a bearer the desktop sends on
 *  every subsequent broker call. */
export interface StoredSession {
  bearer: string;
  expires_at: number;
  sub: string;
  email: string;
  email_verified: boolean;
  organization_id: string | null;
  /** WorkOS first+last name combined. Null when the broker doesn't
   *  have a user row yet (first sign-in race) or WorkOS didn't return
   *  one. Auth store falls back to email in that case. */
  display_name: string | null;
  /** Absolute URL to a WorkOS-hosted avatar, OR the broker-relative
   *  path `/v1/users/me/picture` for user uploads. Null when neither
   *  source has one. Consumers resolve the relative form against the
   *  broker URL. */
  picture_url: string | null;
}

/** Thrown by publish() so the share dialog can switch on `.code` —
 *  `daemon_down` means "start the agent server", anything else is an
 *  upstream/broker failure. */
export class PublishError extends Error {
  constructor(
    public code: "daemon_down" | "upstream",
    message: string,
  ) {
    super(message);
    this.name = "PublishError";
  }
}

// ── Identity (native, offline) ────────────────────────────────────

/** Load the current identity, or null if not yet minted. */
export async function loadIdentity(): Promise<IdentityView | null> {
  return invoke<IdentityView | null>("identity_load");
}

/** Mint a fresh keypair (or return existing one — idempotent).
 *  Optionally bind a handle + WorkOS user-id in one call. */
export async function generateIdentity(opts?: {
  handle?: string;
  workosUserId?: string;
}): Promise<IdentityView> {
  return invoke<IdentityView>("identity_generate", {
    handle: opts?.handle ?? null,
    workosUserId: opts?.workosUserId ?? null,
  });
}

export async function setHandle(handle: string): Promise<IdentityView> {
  return invoke<IdentityView>("identity_set_handle", { handle });
}

export async function setWorkosUserId(
  workosUserId: string | null,
): Promise<IdentityView> {
  return invoke<IdentityView>("identity_set_workos", { workosUserId });
}

// ── Publisher (runtime, graceful-offline) ─────────────────────────

/** Publish a signed workbook to the broker via the control-plane.
 *  Local tangle+sign happens host-side first; this call ships the
 *  resulting share to the broker. The runtime route is
 *  `POST /v1/network/shares`. When the daemon is offline this throws a
 *  typed PublishError("daemon_down") instead of letting the raw
 *  transport error bubble. */
export async function publish(args: PublishArgs): Promise<PublishResult> {
  try {
    return await engineRequest<PublishResult>("/v1/network/shares", {
      method: "POST",
      body: args,
    });
  } catch (e) {
    if (e instanceof EngineApiError && e.code === "daemon_down") {
      throw new PublishError(
        "daemon_down",
        "The agent server isn't running — start it to publish.",
      );
    }
    throw new PublishError(
      "upstream",
      e instanceof Error ? e.message : String(e),
    );
  }
}

// ── WorkOS sign-in (RFC 8252 loopback + PKCE, native) ─────────────

/** Runs the loopback+PKCE sign-in flow: Rust spawns a localhost
 *  callback server, opens the user's system browser to WorkOS, and
 *  exchanges the returned code for a bearer token. The token is
 *  stashed in the OS keychain by the Rust side. Resolves with the
 *  WorkOS user record once the user finishes signing in (and the
 *  browser tab self-closes via the "you're signed in" page). */
export async function workosSignIn(
  brokerUrl: string,
  organizationId?: string,
): Promise<StoredSession> {
  // Unsigned DEV builds can't reliably register the workbooks:// URL scheme on macOS
  // (LaunchServices only trusts a signed, Info.plist-declared handler), so dev uses the
  // loopback flow. Signed RELEASE builds use the native deep link below.
  if (import.meta.env.DEV) {
    return invoke<StoredSession>("workos_sign_in", {
      brokerUrl,
      organizationId: organizationId ?? null,
    });
  }

  // Deep-link flow (the idiomatic Tauri pattern): arm a one-shot listener for the
  // workbooks://auth/callback?code=… deep link, THEN open the browser. The OS routes
  // the callback straight back to the app — no loopback server, no tab to close.
  // organizationId scopes the sign-in to a specific org (the switcher).
  const code = await new Promise<string>((resolve, reject) => {
    let unlisten: (() => void) | undefined;
    const finish = (fn: () => void) => {
      clearTimeout(timer);
      unlisten?.();
      fn();
    };
    const timer = setTimeout(
      () => finish(() => reject(new Error("Sign-in timed out — please try again."))),
      300_000,
    );

    onOpenUrl((urls) => {
      const hit = urls.find((u) => u.startsWith("workbooks://"));
      if (!hit) return;
      let c: string | null = null;
      let err: string | null = null;
      try {
        const u = new URL(hit);
        c = u.searchParams.get("code");
        err = u.searchParams.get("error");
      } catch {
        // malformed — fall through to the rejection below
      }
      if (c) finish(() => resolve(c));
      else finish(() => reject(new Error(err === "access_denied" ? "Sign-in cancelled." : "No code in callback.")));
    })
      .then((fn) => {
        unlisten = fn;
        // Arm-then-open: only launch the browser once the listener is live.
        return invoke("workos_sign_in_begin", { brokerUrl, organizationId: organizationId ?? null });
      })
      .catch((e) => finish(() => reject(e instanceof Error ? e : new Error(String(e)))));
  });

  return invoke<StoredSession>("workos_exchange", { brokerUrl, code });
}

/** Read a previously-stashed session from the OS keychain. Returns
 *  `null` when no session is stored — the auth store treats that as
 *  signed-out. Used on app boot to skip the sign-in prompt for users
 *  who've already authenticated on this machine. */
export async function loadStoredSession(): Promise<StoredSession | null> {
  return invoke<StoredSession | null>("workos_load_session");
}

/** Wipe the stored session. Resolves once the keychain entry is
 *  gone (or was never there). */
export async function clearStoredSession(): Promise<void> {
  return invoke<void>("workos_clear_session");
}

// ── Workspace packager (native, local tangle+sign) ────────────────

/** Bundles a workspace's folders into a single signed-publishable
 *  workbook `.html`. Returns the path Publisher can hand to publish(). */
export async function packageWorkspace(workspaceName: string): Promise<string> {
  return invoke<string>("workspace_package", { workspaceName });
}

// ── Workgate install (native) ─────────────────────────────────────

export interface WorkgateScopes {
  fs?: string[];
  net?: string[];
  tools?: string[];
}

export interface WorkgateInstallArgs {
  rid: string;
  workspace: string;
  scopes: WorkgateScopes;
}

export interface WorkgateInstallResult {
  installed: boolean;
  install_path: string;
}

/** Approve + install an executable share (agent/plugin/skill) into a
 *  workspace. The Tauri shell prompts for OS-level capability approval
 *  via Workgate, then the host clones + verifies + registers. Fetching
 *  a non-local source by RID still needs the broker (pending). */
export async function workgateInstall(
  args: WorkgateInstallArgs,
): Promise<WorkgateInstallResult> {
  return invoke<WorkgateInstallResult>("workgate_install", { args });
}

// ── Workbook fork (native) ────────────────────────────────────────

export interface WorkbookForkArgs {
  source_rid: string;
  source_did: string;
  source_handle?: string | null;
  workspace: string;
}

export interface WorkbookForkResult {
  rid: string;
  fork_path: string;
}

/** Fork a workbook into a fresh RID owned by the current identity.
 *  The host clones the source, mints a new RID, and re-signs the
 *  workbook with a `c2pa.action.forked` assertion + extended claim
 *  chain referencing the upstream's current claim as parent. Forking a
 *  non-local source still needs the broker (pending). */
export async function workbookFork(
  args: WorkbookForkArgs,
): Promise<WorkbookForkResult> {
  return invoke<WorkbookForkResult>("workbook_fork", { args });
}
