// Phase B — MCP server registry store (native).
//
// Index persists in ~/.oql/desktop/mcp-servers.json. UI-only consumption
// today; the oql-agent doesn't read it yet — file a follow-up bd if
// agent-side consumption requires runtime changes.

import { invoke } from "@tauri-apps/api/core";

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

  async init() {
    if (this.#initStarted) return;
    this.#initStarted = true;
    await this.refresh();
  }

  dispose() {}

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
