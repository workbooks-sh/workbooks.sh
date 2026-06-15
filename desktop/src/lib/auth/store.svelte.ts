/**
 * App-level auth + connectivity state.
 *
 * Two concerns the entire desktop app cares about, kept here so they
 * aren't duplicated in every panel:
 *
 *   1. `sidecarReachable` — can the renderer reach Workhorse (the
 *      bundled Tauri sidecar) at all? When this is false the app
 *      can't read identity, can't publish, can't do anything network-
 *      adjacent. The +layout overlay surfaces a full-page
 *      "Restart Workbooks" prompt and the rest of the UI hides.
 *
 *   2. `signedIn` — does the user have a current Workbooks session
 *      (cookie on the broker)? When false the +layout overlay asks
 *      for sign-in. We don't surface the underlying auth provider in
 *      copy — users sign into "Workbooks", full stop.
 *
 * Usage:
 *   import { auth } from "$lib/auth/store.svelte";
 *   onMount(() => auth.init());
 *   if (auth.status === "signed-in") { … }
 */

import {
  clearStoredSession,
  loadIdentity,
  loadStoredSession,
  workosSignIn,
  type IdentityView,
  type StoredSession,
} from "$lib/bridge/network.svelte";

export type AuthStatus =
  | "checking"          // probe in flight
  | "sidecar-offline"   // Tauri bridge / Workhorse not reachable (no session either)
  | "signed-out"        // no Workbooks session
  | "signed-in";        // valid keychain session

export interface AuthUser {
  /** WorkOS sub (or magic-link user id) — opaque identifier. */
  sub: string;
  email: string;
  /** WorkOS organization the session belongs to. Null for personal
   *  (no-org) sessions. Surfaced for org-provisioned features (keys). */
  organizationId: string | null;
  /** Display name from the user record, when present. */
  displayName: string | null;
  /** Profile picture URL — absolute (WorkOS-hosted) or
   *  broker-relative (`/v1/users/me/picture` for user uploads).
   *  `null` when neither source has one. Renderers prepend the
   *  broker URL for relative values. */
  picture: string | null;
}

const DEFAULT_BROKER_URL = "https://auth.workbooks.sh";

function envOverride(key: string): string | undefined {
  return (import.meta.env as Record<string, string | undefined>)?.[key];
}

class AuthStore {
  status = $state<AuthStatus>("checking");
  user = $state<AuthUser | null>(null);
  /** Bound identity from Workhorse — null until the user mints one, OR
   *  null whenever the sidecar is offline (identity needs the daemon). */
  identity = $state<IdentityView | null>(null);
  /** Engine/sidecar reachability — decoupled from auth. The keychain
   *  session determines signed-in/out REGARDLESS of this flag
   *  (offline-first boot canon: the engine shows in the titlebar, it is
   *  never an auth gate). True only when the sidecar probe failed. */
  sidecarOffline = $state(false);
  /** Last init/refresh error (if any), for surfacing in overlays. */
  lastError = $state<string | null>(null);

  #brokerUrl = envOverride("PUBLIC_BROKER_URL") ?? DEFAULT_BROKER_URL;
  #initialized = false;

  /** Run on app mount. Re-runs are no-ops; use refresh() to re-probe. */
  async init(): Promise<void> {
    if (this.#initialized) return;
    this.#initialized = true;
    await this.refresh();
  }

  /** Probe sidecar + read any keychain-stored session. Idempotent.
   *
   *  Offline-first: the keychain SESSION read is what determines
   *  signed-in/out, and it runs REGARDLESS of whether the sidecar is
   *  reachable. The Workhorse `identity` does need the sidecar, so it
   *  becomes null (and `sidecarOffline` flips true) when the daemon is
   *  down — but a user with a stored session is still "signed-in". This
   *  is the offline-first boot canon: the engine state belongs in the
   *  titlebar chip, never as an auth gate. */
  async refresh(): Promise<void> {
    this.status = "checking";
    this.lastError = null;

    // 1. Sidecar probe — best-effort. Failure does NOT gate auth; it
    //    only nulls the bound identity and raises the engine-offline
    //    flag (surfaced in the titlebar engine chip / Sidebar — never a
    //    blocking overlay; mandatory sign-in is the only hard gate).
    try {
      this.identity = await loadIdentity();
      this.sidecarOffline = false;
    } catch {
      this.identity = null;
      this.sidecarOffline = true;
    }

    // 2. Session probe — read the keychain. The desktop owns its own
    //    bearer token (loopback+PKCE flow); no daemon involved. If the
    //    keychain entry exists the user is signed in until they sign
    //    out — even with the engine offline.
    try {
      const session = await loadStoredSession();
      if (session) {
        this.#applySession(session);
      } else {
        this.user = null;
        this.status = "signed-out";
      }
    } catch (e) {
      this.status = "signed-out";
      this.lastError = e instanceof Error ? e.message : String(e);
      this.user = null;
    }
  }

  /** Walk the user through sign-in: open system browser to WorkOS,
   *  catch the loopback callback, exchange the code, stash bearer
   *  token in the OS keychain. On success the auth store transitions
   *  to "signed-in" using the user record from the same response. */
  async signIn(): Promise<void> {
    try {
      const session = await workosSignIn(this.#brokerUrl);
      this.#applySession(session);
      this.lastError = null;
    } catch (e) {
      this.lastError = e instanceof Error ? e.message : String(e);
      throw e;
    }
  }

  /** Sign out locally — wipe the keychain entry. There's no broker
   *  cookie to clear in the loopback model (the broker's session
   *  ledger isn't on the auth path; revocation of WorkOS refresh
   *  tokens is a separate concern handled by token rotation). */
  async signOut(): Promise<void> {
    try {
      await clearStoredSession();
    } catch (e) {
      this.lastError = e instanceof Error ? e.message : String(e);
    }
    this.user = null;
    this.status = "signed-out";
  }

  #applySession(session: StoredSession): void {
    this.user = {
      sub: session.sub,
      email: session.email,
      organizationId: session.organization_id ?? null,
      displayName: session.display_name ?? null,
      picture: this.#resolvePicture(session.picture_url ?? null),
    };
    this.status = "signed-in";
  }

  /** Broker may return picture_url as either absolute (WorkOS-hosted
   *  CDN) or as the relative path `/v1/users/me/picture` when the user
   *  uploaded a custom avatar. Resolve the relative form against the
   *  configured broker URL so consumers can use the value as `<img src>`
   *  without knowing which case they're in. */
  #resolvePicture(raw: string | null): string | null {
    if (!raw) return null;
    if (raw.startsWith("http://") || raw.startsWith("https://")) return raw;
    return `${this.#brokerUrl}${raw}`;
  }

  get brokerUrl(): string {
    return this.#brokerUrl;
  }
}

/** Singleton. Components import this and read reactive fields. */
export const auth = new AuthStore();
