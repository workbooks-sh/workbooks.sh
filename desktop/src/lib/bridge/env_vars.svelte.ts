/**
 * Env-vars bridge — mirrors Rust `env_vars.rs`.
 *
 * User-managed environment variables, scoped to one of:
 *   - "user"      (everywhere)
 *   - "workspace" (one workspace; available across its packages)
 *   - "package"   (one package only)
 *
 * Values are kept on disk; the list endpoint returns redacted views
 * (no raw value). Use `reveal(id)` to fetch a single secret for a
 * user-driven action.
 */

import { invoke } from "@tauri-apps/api/core";

export type EnvScope = "user" | "workspace" | "package";

export interface EnvVarRedacted {
  id: string;
  name: string;
  scope: EnvScope;
  workspace_id: string | null;
  package_name: string | null;
  created_at: number;
  /** Always 8 bullets — UI swaps in the reveal value on click. */
  masked: string;
  /** Real char length, useful for "looks valid" affordances. */
  length: number;
}

export interface EnvVarCreate {
  name: string;
  value: string;
  scope: EnvScope;
  workspace_id?: string;
  package_name?: string;
}

export interface BulkImportRequest {
  text: string;
  scope: EnvScope;
  workspace_id?: string;
  package_name?: string;
}

export interface BulkImportResult {
  imported: EnvVarRedacted[];
  skipped: string[];
}

class EnvVarsStore {
  vars = $state<EnvVarRedacted[]>([]);
  loading = $state(false);
  lastError = $state<string | null>(null);

  /** Mirrors keys.dirty — the agent needs a restart to pick up
   *  changed env. We set this flag on every mutation; UI surfaces it. */
  dirty = $state(false);

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
      this.vars = await invoke<EnvVarRedacted[]>("env_vars_list");
    } catch (e) {
      this.lastError = e instanceof Error ? e.message : String(e);
    } finally {
      this.loading = false;
    }
  }

  // No `dirty` flipping — secret updates land via Rust's push to the
  // sidecar (/internal/secrets/refresh). Env vars are also not yet
  // read by any sidecar code; the push will start covering them when
  // tool runtime support lands.

  async create(req: EnvVarCreate): Promise<EnvVarRedacted> {
    const v = await invoke<EnvVarRedacted>("env_vars_create", { req });
    await this.refresh();
    return v;
  }

  async update(id: string, value: string): Promise<void> {
    await invoke("env_vars_update", { req: { id, value } });
    await this.refresh();
  }

  async delete(id: string): Promise<void> {
    await invoke("env_vars_delete", { id });
    await this.refresh();
  }

  /** Decrypts in Rust and writes straight to the OS clipboard. The
   *  plaintext never returns to JS. See `keys.copyToClipboard` for
   *  the threat-model rationale. */
  async copyToClipboard(id: string): Promise<void> {
    await invoke<void>("env_vars_copy_to_clipboard", { id });
  }

  async bulkImport(req: BulkImportRequest): Promise<BulkImportResult> {
    const result = await invoke<BulkImportResult>("env_vars_bulk_import", {
      req,
    });
    await this.refresh();
    return result;
  }
}

export const envVars = new EnvVarsStore();
