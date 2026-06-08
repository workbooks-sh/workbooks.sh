// Connections store — third-party integrations (Composio, Doppler,
// GitHub). The api key itself never lives in JS state; `list()`
// returns redacted records with only the metadata needed to render
// the connected-service card.
//
// Phase B placement:
//   - NATIVE (offline): connections_list/create/delete read+write the
//     OS keychain (secrets) + a redacted index on disk. Secrets never
//     cross IPC — only redacted metadata + key_length come back.
//   - RUNTIME (graceful-offline): listComposioAccounts hits the
//     control-plane GET /api/integrations/composio/connections; the
//     Elixir side reads COMPOSIO_API_KEY from env and calls Composio.
//     When the daemon is down it returns a typed ComposioListError so
//     the picker renders an actionable empty-state instead of throwing
//     a raw transport error.
//
// Each connection forwards an env var into the daemon at spawn
// (`COMPOSIO_API_KEY`, `DOPPLER_TOKEN`, etc.). The runtime
// connections.changed firehose is pending; for now we refresh the
// store directly after every mutation.

import { invoke } from "@tauri-apps/api/core";
import { engineRequest, EngineApiError } from "$lib/engine-api/gen";

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
   *  restart flow over in IntegrationsSettings. */
  dirty = $state(false);

  async init() {
    await this.refresh();
  }

  dispose() {
    // No live subscription to tear down — runtime connections.changed
    // firehose is pending; mutations refresh directly.
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

  // Mutations: Rust persists the connection (secret in OS keychain)
  // then pushes the new env var to the live daemon via
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

  /** Fetch the user's connected Composio accounts via the daemon.
   *  The Elixir side reads `COMPOSIO_API_KEY` from env (forwarded by
   *  the Rust spawn) and calls Composio's REST API; the renderer
   *  never sees the API key.
   *
   *  Returns the list, or throws a typed error so the picker modal
   *  can render an actionable message (daemon down, missing key,
   *  upstream down). */
  async listComposioAccounts(): Promise<ComposioAccount[]> {
    try {
      const body = await engineRequest<{ connections?: ComposioAccount[] }>(
        "/api/integrations/composio/connections",
      );
      return body.connections ?? [];
    } catch (e) {
      if (e instanceof EngineApiError) {
        if (e.code === "daemon_down") {
          throw new ComposioListError(
            "daemon_down",
            "The agent server isn't running yet.",
          );
        }
        if (e.status === 412) {
          throw new ComposioListError(
            "no_api_key",
            e.message ||
              "Connect Composio in Settings → Integrations to populate this list.",
          );
        }
        throw new ComposioListError(
          "upstream",
          e.message || `Composio API returned ${e.status}`,
        );
      }
      throw new ComposioListError(
        "upstream",
        e instanceof Error ? e.message : String(e),
      );
    }
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
    public code: "daemon_down" | "no_api_key" | "upstream",
    message: string,
  ) {
    super(message);
    this.name = "ComposioListError";
  }
}

export const connections = new ConnectionsStore();
