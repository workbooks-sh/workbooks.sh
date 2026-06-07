/**
 * auth — app-level account + connectivity state, the single source of
 * truth every entry point reads (rail account button, account menu, the
 * route guard). Two concerns the whole app cares about:
 *
 *   1. sidecar reachability — can the renderer reach the engine at all?
 *      When false, nothing network-adjacent works and the route guard
 *      hard-gates to the offline view.
 *   2. session — does the user have a current Workbooks session? Sign-in
 *      is OPTIONAL (the app works without it) but enables publish +
 *      network. We never name the underlying auth provider in copy — to
 *      the user this is just "sign in to Workbooks."
 *
 * `status` is the derived state machine the UI switches on. `identity` is
 * the bound network handle (null until the user mints one). Backed by the
 * mocked IPC command layer today; the real shell drives the WorkOS PKCE
 * loopback flow + OS keychain behind the same method signatures.
 */

import { commands, type IdentityView } from "./bindings";

export type AuthStatus =
  | "checking" // probe in flight
  | "sidecar-offline" // engine unreachable — hard gate
  | "signed-out" // engine OK, no session
  | "signed-in"; // engine OK + valid session

/** Engine lifecycle, surfaced in the account-menu status dashboard. */
export type EngineState = "ok" | "starting" | "unhealthy" | "stopped";

export interface User {
  email: string;
  displayName?: string | null;
  picture?: string | null;
}

const DEFAULT_BROKER_URL = "https://auth.workbooks.sh";

class AuthStore {
  status = $state<AuthStatus>("checking");
  user = $state<User | null>(null);
  /** Bound network identity — null until the user mints one. */
  identity = $state<IdentityView | null>(null);
  /** Engine lifecycle state for the status dashboard. */
  engineState = $state<EngineState>("starting");
  busy = $state<boolean>(false);
  resetting = $state<boolean>(false);
  lastError = $state<string | null>(null);

  #brokerUrl = DEFAULT_BROKER_URL;
  #initStarted = false;

  /** The route guard reads this — the only hard gate. */
  sidecarReachable = $derived(this.status !== "sidecar-offline");
  signedIn = $derived(this.status === "signed-in");

  /** Run on app mount. Re-runs are no-ops; use refresh() to re-probe. */
  async init(): Promise<void> {
    if (this.#initStarted) return;
    this.#initStarted = true;
    await this.refresh();
  }

  /** Probe engine + read any stored session. Idempotent. */
  async refresh(): Promise<void> {
    this.status = "checking";
    this.lastError = null;

    // 1. Engine probe — an unreachable sidecar is the hard gate.
    try {
      const sc = await commands.sidecarStatus();
      this.engineState = sc.state;
      if (!sc.reachable) {
        this.status = "sidecar-offline";
        this.user = null;
        this.identity = null;
        return;
      }
    } catch (e) {
      this.status = "sidecar-offline";
      this.lastError = msg(e);
      this.user = null;
      this.identity = null;
      return;
    }

    // 2. Bound identity (network handle) — independent of session.
    try {
      this.identity = await commands.networkIdentityLoad();
    } catch {
      this.identity = null;
    }

    // 3. Session probe — read the stored bearer. Present ⇒ signed in
    //    until the user explicitly signs out.
    try {
      const session = await commands.networkWorkosLoadSession();
      if (session) {
        this.user = { email: session.email ?? "you@example.com" };
        this.status = "signed-in";
      } else {
        this.user = null;
        this.status = "signed-out";
      }
    } catch (e) {
      this.user = null;
      this.status = "signed-out";
      this.lastError = msg(e);
    }
  }

  /** Walk the user through sign-in: the shell opens the system browser to
   *  WorkOS, catches the loopback callback, exchanges the code, stashes
   *  the bearer in the OS keychain. On success we transition to signed-in
   *  from the same response. */
  async signIn(): Promise<void> {
    this.busy = true;
    this.lastError = null;
    try {
      const session = await commands.networkWorkosSignIn({ brokerUrl: this.#brokerUrl });
      this.user = { email: session.email ?? "you@example.com" };
      this.status = "signed-in";
    } catch (e) {
      this.lastError = msg(e);
      throw e;
    } finally {
      this.busy = false;
    }
  }

  /** Sign out locally — wipe the stored session. No broker cookie to
   *  clear in the loopback model. */
  async signOut(): Promise<void> {
    this.busy = true;
    try {
      await commands.networkWorkosClearSession();
    } catch (e) {
      this.lastError = msg(e);
    } finally {
      this.user = null;
      this.status = "signed-out";
      this.busy = false;
    }
  }

  /** Escape hatch when a stale session blocks re-auth: wipe local state
   *  and re-probe from the checking baseline. */
  async resetLocalSession(): Promise<void> {
    if (this.resetting) return;
    this.resetting = true;
    try {
      await commands.networkWorkosClearSession();
      await this.refresh();
    } catch (e) {
      this.lastError = msg(e);
    } finally {
      this.resetting = false;
    }
  }

  /** Actually restart the engine process (not just re-probe) — a re-probe
   *  alone never recovers a crashed BEAM or a port conflict. */
  async restartEngine(): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    try {
      await commands.sidecarRestart();
      await this.refresh();
    } catch (e) {
      this.lastError = msg(e);
    } finally {
      this.busy = false;
    }
  }

  get brokerUrl(): string {
    return this.#brokerUrl;
  }
}

function msg(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}

/** Singleton. Components import this and read reactive fields. */
export const auth = new AuthStore();
