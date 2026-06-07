// wb-i38o.6 §2 — MCP server registry store.
//
// UI-only persistence today; the oql-agent doesn't read
// ~/.oql/desktop/mcp-servers.json yet — file a follow-up bd if
// agent-side consumption requires runtime changes.

import { invoke } from "@tauri-apps/api/core";
import { ws } from "./ws.svelte";

export type McpTransport = "stdio" | "http";

export interface McpServer {
  id: string;
  name: string;
  transport: McpTransport;
  command_or_url: string;
  args: string[];
  env: Record<string, string>;
  enabled: boolean;
  created_at: number;
}

export interface McpCreate {
  name: string;
  transport: McpTransport;
  command_or_url: string;
  args: string[];
  env: Record<string, string>;
  enabled: boolean;
}

export interface McpUpdate extends McpCreate {
  id: string;
}

class McpStore {
  servers = $state<McpServer[]>([]);
  loading = $state(false);
  lastError = $state<string | null>(null);

  #initStarted = false;
  #liveUnsub: (() => void) | null = null;

  async init() {
    if (this.#initStarted) return;
    this.#initStarted = true;
    await this.refresh();
    this.#liveUnsub = ws.onMonorepoChange("mcp-servers.org", () => {
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
      this.servers = await invoke<McpServer[]>("mcp_list");
    } catch (e) {
      this.lastError = e instanceof Error ? e.message : String(e);
    } finally {
      this.loading = false;
    }
  }

  async create(req: McpCreate): Promise<McpServer> {
    const s = await invoke<McpServer>("mcp_create", { req });
    await this.refresh();
    return s;
  }

  async update(req: McpUpdate): Promise<McpServer> {
    const s = await invoke<McpServer>("mcp_update", { req });
    await this.refresh();
    return s;
  }

  async delete(id: string): Promise<void> {
    await invoke("mcp_delete", { id });
    await this.refresh();
  }
}

export const mcp = new McpStore();
