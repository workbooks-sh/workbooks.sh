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
import { rcp } from "$lib/rcp";
import { nexus } from "./nexus.svelte";
import { workspaces } from "./workspaces.svelte";

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
  /** Active nexus id at the last refresh — when it changes, re-fetch (env
   *  vars are cloud-backed on the oidc nexus, on-disk on the local one). */
  #lastNexusId: string | null = null;

  /** The cloud/oidc nexus is the team backend; the local nexus stays on disk. */
  get #cloud(): boolean {
    return nexus.activeAuth === "oidc";
  }

  async init() {
    if (this.#initStarted) return;
    this.#initStarted = true;
    // Re-fetch whenever the active nexus changes (cloud ↔ local switch the
    // backend out from under us). One $effect drives both backends.
    $effect.root(() => {
      $effect(() => {
        const id = nexus.activeId;
        if (id !== this.#lastNexusId) {
          this.#lastNexusId = id;
          void this.refresh();
        }
      });
    });
    if (this.#lastNexusId === null) {
      this.#lastNexusId = nexus.activeId;
      await this.refresh();
    }
  }

  dispose() {}

  async refresh() {
    this.loading = true;
    this.lastError = null;
    try {
      if (this.#cloud) {
        const wsId = workspaces.active?.id;
        const { env } = await rcp.request<{ env: EnvVarRedacted[] }>(
          "/api/platform/env",
          { query: wsId ? `?workspace=${wsId}` : "" },
        );
        this.vars = env;
      } else {
        this.vars = await invoke<EnvVarRedacted[]>("env_vars_list");
      }
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
    let v: EnvVarRedacted;
    if (this.#cloud) {
      v = await rcp.request<EnvVarRedacted>("/api/platform/env", {
        method: "POST",
        body: {
          name: req.name,
          value: req.value,
          scope: req.scope,
          workspace_id: req.workspace_id ?? null,
          package_name: req.package_name ?? null,
        },
      });
    } else {
      v = await invoke<EnvVarRedacted>("env_vars_create", { req });
    }
    await this.refresh();
    return v;
  }

  async update(id: string, value: string): Promise<void> {
    if (this.#cloud) {
      await rcp.request(`/api/platform/env/${id}`, {
        method: "PATCH",
        body: { value },
      });
    } else {
      await invoke("env_vars_update", { req: { id, value } });
    }
    await this.refresh();
  }

  async delete(id: string): Promise<void> {
    if (this.#cloud) {
      await rcp.request(`/api/platform/env/${id}`, { method: "DELETE" });
    } else {
      await invoke("env_vars_delete", { id });
    }
    await this.refresh();
  }

  /** Fetch a single secret's plaintext. Cloud → the explicit reveal endpoint;
   *  local has no JS reveal (it decrypts straight to the OS clipboard in Rust —
   *  see `copyToClipboard`). */
  async reveal(id: string): Promise<string> {
    if (!this.#cloud) {
      throw new Error("reveal() unsupported on the local nexus — use copyToClipboard()");
    }
    const { value } = await rcp.request<{ value: string }>(
      `/api/platform/env/${id}/reveal`,
    );
    return value;
  }

  /** Local: decrypts in Rust and writes straight to the OS clipboard — the
   *  plaintext never returns to JS (see `keys.copyToClipboard` for the
   *  threat-model rationale). Cloud: reveal then write from JS. */
  async copyToClipboard(id: string): Promise<void> {
    if (this.#cloud) {
      await navigator.clipboard.writeText(await this.reveal(id));
    } else {
      await invoke<void>("env_vars_copy_to_clipboard", { id });
    }
  }

  async bulkImport(req: BulkImportRequest): Promise<BulkImportResult> {
    if (this.#cloud) {
      // Mirror the Rust parser: per line, skip blanks + `#` comments, split on
      // the first `=`. Loop create; collect imported/skipped.
      const imported: EnvVarRedacted[] = [];
      const skipped: string[] = [];
      for (const raw of req.text.split(/\r?\n/)) {
        const line = raw.trim();
        if (!line || line.startsWith("#")) continue;
        const eq = line.indexOf("=");
        if (eq <= 0) {
          skipped.push(line);
          continue;
        }
        const name = line.slice(0, eq).trim();
        const value = line.slice(eq + 1).trim();
        if (!name) {
          skipped.push(line);
          continue;
        }
        try {
          imported.push(
            await rcp.request<EnvVarRedacted>("/api/platform/env", {
              method: "POST",
              body: {
                name,
                value,
                scope: req.scope,
                workspace_id: req.workspace_id ?? null,
                package_name: req.package_name ?? null,
              },
            }),
          );
        } catch {
          skipped.push(name);
        }
      }
      await this.refresh();
      return { imported, skipped };
    }
    const result = await invoke<BulkImportResult>("env_vars_bulk_import", {
      req,
    });
    await this.refresh();
    return result;
  }
}

export const envVars = new EnvVarsStore();
