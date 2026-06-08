/**
 * Bridge: Workbooks Network — desktop ↔ oql-agent IPC (wb-u2o0.9.1).
 *
 * Thin typed wrappers around the Tauri commands in
 * `src-tauri/src/network.rs`. The desktop UI consumes this module in
 * place of the Phase 1 stubs (ConnectFlow, ShareDialog, etc.) so
 * each user action actually runs through Workhorse + Broker.
 */

import { invoke } from "@tauri-apps/api/core";

// ── Types — mirror src-tauri/src/network.rs structs ───────────────

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

// ── Identity ──────────────────────────────────────────────────────

/** Load the current identity, or null if not yet minted. */
export async function loadIdentity(): Promise<IdentityView | null> {
  return invoke<IdentityView | null>("network_identity_load");
}

/** Mint a fresh keypair (or return existing one — idempotent).
 *  Optionally bind a handle + WorkOS user-id in one call. */
export async function generateIdentity(opts?: {
  handle?: string;
  workosUserId?: string;
}): Promise<IdentityView> {
  return invoke<IdentityView>("network_identity_generate", {
    handle: opts?.handle ?? null,
    workosUserId: opts?.workosUserId ?? null,
  });
}

export async function setHandle(handle: string): Promise<IdentityView> {
  return invoke<IdentityView>("network_identity_set_handle", { handle });
}

export async function setWorkosUserId(
  workosUserId: string | null,
): Promise<IdentityView> {
  return invoke<IdentityView>("network_identity_set_workos", { workosUserId });
}

// ── Publisher ─────────────────────────────────────────────────────

export async function publish(args: PublishArgs): Promise<PublishResult> {
  return invoke<PublishResult>("network_publisher_publish", { args });
}

// ── WorkOS sign-in (RFC 8252 loopback + PKCE) ─────────────────────

/** Runs the loopback+PKCE sign-in flow: Rust spawns a localhost
 *  callback server, opens the user's system browser to WorkOS, and
 *  exchanges the returned code for a bearer token. The token is
 *  stashed in the OS keychain by the Rust side. Resolves with the
 *  WorkOS user record once the user finishes signing in (and the
 *  browser tab self-closes via the "you're signed in" page). */
export async function workosSignIn(brokerUrl: string): Promise<StoredSession> {
  return invoke<StoredSession>("network_workos_sign_in", { brokerUrl });
}

/** Read a previously-stashed session from the OS keychain. Returns
 *  `null` when no session is stored — the auth store treats that as
 *  signed-out. Used on app boot to skip the sign-in prompt for users
 *  who've already authenticated on this machine. */
export async function loadStoredSession(): Promise<StoredSession | null> {
  return invoke<StoredSession | null>("network_workos_load_session");
}

/** Wipe the stored session. Resolves once the keychain entry is
 *  gone (or was never there). */
export async function clearStoredSession(): Promise<void> {
  return invoke<void>("network_workos_clear_session");
}

// ── Workspace packager (wb-u2o0.9.3) ──────────────────────────────

/** Bundles a workspace's folders into a single signed-publishable
 *  workbook `.html`. Returns the path Publisher can hand to publish(). */
export async function packageWorkspace(workspaceName: string): Promise<string> {
  return invoke<string>("network_workspace_package", { workspaceName });
}

// ── Workgate install (wb-u2o0.4.5) ─────────────────────────────────

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
 *  via Workgate, then Workhorse clones + verifies + registers. Phase 3
 *  v1 stubs the approval (auto-yes) — full Workgate UI lands as a
 *  separate sub-task. */
export async function workgateInstall(args: WorkgateInstallArgs): Promise<WorkgateInstallResult> {
  return invoke<WorkgateInstallResult>("network_workgate_install", { args });
}

// ── Workbook fork (wb-u2o0.6.2) ────────────────────────────────────

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
 *  Workhorse clones the source, mints a new RID, and re-signs the
 *  workbook with a `c2pa.action.forked` assertion + extended claim
 *  chain referencing the upstream's current claim as parent. v1
 *  stubs the chain extension; full impl in a follow-up. */
export async function workbookFork(args: WorkbookForkArgs): Promise<WorkbookForkResult> {
  return invoke<WorkbookForkResult>("network_workbook_fork", { args });
}
