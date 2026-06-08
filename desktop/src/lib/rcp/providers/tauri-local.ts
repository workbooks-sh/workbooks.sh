// The LOCAL provider — the only Tauri/Svelte-coupled RCP file. It wires the
// desktop discovery (the `sidecar` store, fed by daemon.rs runtime.json) into a
// portable RcpTarget, then exposes a singleton RcpClient the app uses.
//
// A web/html/mobile client would instead supply a `url` provider (configured
// base URL + an OidcAdapter) — same RcpClient, different target. That symmetry
// is the whole point of RCP.

import { sidecar } from "$lib/bridge/sidecar.svelte";
import { LocalTokenAdapter } from "../adapters";
import { RcpClient } from "../client";
import type { RcpTarget } from "../types";

/** Target backed by the local daemon discovery (trusted rung). */
const localTarget: RcpTarget = {
  getBaseUrl: () => sidecar.status.url,
  auth: new LocalTokenAdapter(() => sidecar.status.token),
};

/** The app-wide RCP client for the local runtime. */
export const rcp = new RcpClient(localTarget);
