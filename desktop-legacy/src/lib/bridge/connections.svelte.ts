// Connections store — third-party integrations (Composio, Doppler,
// GitHub). The api key itself never lives in JS state; `list()`
// returns redacted records with only the metadata needed to render
// the connected-service card.
//
// Sidecar coupling: each connection forwards an env var into the
// sidecar at spawn (`COMPOSIO_API_KEY`, `DOPPLER_TOKEN`, etc.) so
// the Elixir-side SDK calls can authenticate. Changing a connection
// requires a sidecar restart, surfaced via the shared `dirty` flag
// the existing IntegrationsSettings panel already handles.

import { invoke } from "@tauri-apps/api/core";
import { sidecar } from "./sidecar.svelte";
import { ws } from "./ws.svelte";

export type ConnectionService =
  // Cloud integration services.
  | "composio"
  | "doppler"
  // Custom-OAuth-we-host (broker-mediated) integrations.
  | "github"
  | "meta"
  // AI providers (paste-API-key shape).
  | "open_router"
  | "fal"
  | "gemini"
  // Local-CLI connections — detect-on-PATH flow (deferred).
  | "claude_code"
  | "codex"
  | "google_workspace";

export interface ConnectionRedacted {
  id: string;
  service: ConnectionService;
  account_label: string | null;
  dashboard_url: string;
  env_var_name: string;
  created_at: number;
  key_length: number;
}

export interface ConnectionCreate {
  service: ConnectionService;
  api_key: string;
  account_label?: string;
}

class ConnectionsStore {
  connections = $state<ConnectionRedacted[]>([]);
  loading = $state(false);
  lastError = $state<string | null>(null);

  /** Mutated by every connect/disconnect; cleared by the shared
   *  restartSidecar flow over in IntegrationsSettings. */
  dirty = $state(false);

  #liveUnsub: (() => void) | null = null;

  async init() {
    await this.refresh();
    this.#liveUnsub = ws.onMonorepoChange("connections.org", () => {
      void this.refresh();
    });
  }

  dispose() {
    this.#liveUnsub?.();
    this.#liveUnsub = null;
  }

  async refresh() {
    this.loading = true;
    this.lastError = null;
    try {
      this.connections = await invoke<ConnectionRedacted[]>("connections_list");
    } catch (e) {
      this.lastError = e instanceof Error ? e.message : String(e);
    } finally {
      this.loading = false;
    }
  }

  /** Lookup by service id — there's at most one connection per
   *  service in v1 (Rust replaces on create). */
  forService(service: ConnectionService): ConnectionRedacted | null {
    return this.connections.find((c) => c.service === service) ?? null;
  }

  // Mutations: Rust persists the connection (encrypted at rest) then
  // pushes the new env var to the live sidecar via
  // /internal/secrets/refresh — no restart needed.

  async connect(req: ConnectionCreate): Promise<ConnectionRedacted> {
    const created = await invoke<ConnectionRedacted>("connections_create", {
      req,
    });
    await this.refresh();
    return created;
  }

  async disconnect(id: string): Promise<void> {
    await invoke("connections_delete", { id });
    await this.refresh();
  }

  /** Fetch the user's connected Composio accounts via the sidecar.
   *  The Elixir side reads `COMPOSIO_API_KEY` from env (forwarded by
   *  the Rust spawn) and calls Composio's REST API; the renderer
   *  never sees the API key.
   *
   *  Returns the list, or throws a typed error so the picker modal
   *  can render an actionable message (missing key, upstream down). */
  async listComposioAccounts(): Promise<ComposioAccount[]> {
    if (!sidecar.status.url) {
      throw new ComposioListError(
        "sidecar_down",
        "The agent server isn't running yet.",
      );
    }
    const res = await fetch(
      `${sidecar.status.url}/api/integrations/composio/connections`,
      { headers: { accept: "application/json" } },
    );
    const body = await res.json().catch(() => ({}));
    if (res.ok) return body.connections ?? [];
    if (res.status === 412) {
      throw new ComposioListError(
        "no_api_key",
        body.message ??
          "Connect Composio in Settings → Integrations to populate this list.",
      );
    }
    throw new ComposioListError(
      "upstream",
      body.message ?? `Composio API returned ${res.status}`,
    );
  }
}

export interface ComposioAccount {
  id: string;
  status: string;
  toolkit_slug: string;
  auth_scheme: string | null;
  created_at: number | null;
}

/** Typed error for the Composio list call. The picker modal switches
 *  on `.code` to render the right empty-state. */
export class ComposioListError extends Error {
  constructor(
    public code: "sidecar_down" | "no_api_key" | "upstream",
    message: string,
  ) {
    super(message);
    this.name = "ComposioListError";
  }
}

export const connections = new ConnectionsStore();
