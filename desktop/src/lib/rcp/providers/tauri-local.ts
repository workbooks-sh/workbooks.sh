// The LOCAL provider — the only Tauri/Svelte-coupled RCP file. It wires the
// desktop discovery (the `sidecar` store, fed by daemon.rs runtime.json) into a
// portable RcpTarget, then exposes a singleton RcpClient the app uses.
//
// A web/html/mobile client would instead supply a `url` provider (configured
// base URL + an OidcAdapter) — same RcpClient, different target. That symmetry
// is the whole point of RCP.

import { auth } from "$lib/auth/store.svelte";
import { nexus } from "$lib/bridge/nexus.svelte";
import { LocalTokenAdapter } from "../adapters";
import { RcpClient } from "../client";
import type { AuthAdapter, RcpTarget } from "../types";
import { workosAdapter } from "./workos";

/** Static-token rung: the local discovery token or a per-nexus bearer. */
const tokenAdapter = new LocalTokenAdapter(() => nexus.activeToken);
/** OIDC rung: the WorkOS keychain session (auto-renewing JWT). */
const oidcAdapter = workosAdapter(auth.brokerUrl);

/** Pick the adapter for whichever nexus is active. An `oidc` nexus (the cloud
 *  control plane) authenticates with the WorkOS session; everything else uses
 *  the static-token rung. Resolved per-call so switching nexuses takes effect
 *  immediately without rebuilding the client. */
const activeAuth: AuthAdapter = {
  getToken: () =>
    (nexus.activeAuth === "oidc" ? oidcAdapter : tokenAdapter).getToken(),
};

/** Target backed by the ACTIVE nexus (wb-aakl.9). The default nexus is
 *  `local`, whose base URL + token resolve live from the daemon discovery
 *  (the `sidecar` store, fed by runtime.json); the user can switch to a
 *  saved remote nexus and every RCP call follows. Same RcpClient, the
 *  target just reads a different endpoint — that symmetry is RCP's point. */
const activeTarget: RcpTarget = {
  getBaseUrl: () => nexus.activeUrl,
  auth: activeAuth,
};

/** The app-wide RCP client — points at whichever nexus is active. */
export const rcp = new RcpClient(activeTarget);
