// The LOCAL provider — the only Tauri/Svelte-coupled RCP file. It wires the
// desktop discovery (the `sidecar` store, fed by daemon.rs runtime.json) into a
// portable RcpTarget, then exposes a singleton RcpClient the app uses.
//
// A web/html/mobile client would instead supply a `url` provider (configured
// base URL + an OidcAdapter) — same RcpClient, different target. That symmetry
// is the whole point of RCP.

import { nexus } from "$lib/bridge/nexus.svelte";
import { LocalTokenAdapter } from "../adapters";
import { RcpClient } from "../client";
import type { RcpTarget } from "../types";

/** Target backed by the ACTIVE nexus (wb-aakl.9). The default nexus is
 *  `local`, whose base URL + token resolve live from the daemon discovery
 *  (the `sidecar` store, fed by runtime.json); the user can switch to a
 *  saved remote nexus and every RCP call follows. Same RcpClient, the
 *  target just reads a different endpoint — that symmetry is RCP's point. */
const activeTarget: RcpTarget = {
  getBaseUrl: () => nexus.activeUrl,
  auth: new LocalTokenAdapter(() => nexus.activeToken),
};

/** The app-wide RCP client — points at whichever nexus is active. */
export const rcp = new RcpClient(activeTarget);
