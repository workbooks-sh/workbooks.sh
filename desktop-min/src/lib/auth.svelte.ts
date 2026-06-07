/**
 * auth — app-level account + sidecar reachability state.
 *
 * Sign-in is OPTIONAL (the app works without an account) but enables
 * publish + network. At boot we probe the sidecar and load any stored
 * WorkOS session; the rail's account button and the route guard both
 * read from here so every entry point reflects one source of truth.
 *
 * Backed by the mocked IPC command layer today. The route guard treats
 * an unreachable sidecar as the only hard gate; signed-out is allowed.
 */

import { commands } from "./bindings";

export interface User {
  email: string;
  displayName?: string | null;
}

class AuthStore {
  user = $state<User | null>(null);
  sidecarReachable = $state<boolean>(true);
  busy = $state<boolean>(false);
  lastError = $state<string | null>(null);

  #initStarted = false;
  signedIn = $derived(this.user !== null);

  async init() {
    if (this.#initStarted) return;
    this.#initStarted = true;
    try {
      const status = await commands.sidecarStatus();
      this.sidecarReachable = status.reachable;
      const session = await commands.networkWorkosLoadSession();
      if (session) this.user = { email: session.email ?? "you@example.com" };
    } catch (e) {
      this.lastError = e instanceof Error ? e.message : String(e);
    }
  }

  async signIn(brokerUrl = "https://broker.invalid") {
    this.busy = true;
    this.lastError = null;
    try {
      const session = await commands.networkWorkosSignIn({ brokerUrl });
      this.user = { email: session.email ?? "you@example.com" };
    } catch (e) {
      this.lastError = e instanceof Error ? e.message : String(e);
    } finally {
      this.busy = false;
    }
  }

  async signOut() {
    this.busy = true;
    try {
      await commands.networkWorkosClearSession();
      this.user = null;
    } finally {
      this.busy = false;
    }
  }
}

export const auth = new AuthStore();
