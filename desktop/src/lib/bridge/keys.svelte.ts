// Phase B — API key store (native, OS-keychain backed).
//
// Secrets in OS keychain; redacted index in `~/.oql/desktop/keys.json`.
// The keys themselves never live in JS state — `refresh()` returns
// redacted views (masked dots + length), and the raw secret is only
// fetched on user-driven reveal via `reveal(id)`. This keeps a single
// devtools `console.log(store)` from leaking secrets.
//
// Daemon coupling: the Elixir oql-agent reads provider env vars at
// boot (`OPENROUTER_API_KEY`, `ANTHROPIC_API_KEY`, etc.). Changing
// keys may require a daemon restart — the UI surfaces a warning chip
// after a mutation and exposes `restartSidecar()` (now wired to the
// `daemon_restart` command) to actually do it.

import { invoke } from "@tauri-apps/api/core";

export interface ApiKeyRedacted {
  id: string;
  name: string;
  provider: string;
  custom_provider: string | null;
  created_at: number;
  masked: string;
  length: number;
}

export interface KeyCreate {
  name: string;
  provider: string;
  custom_provider?: string;
  value: string;
}

class KeysStore {
  keys = $state<ApiKeyRedacted[]>([]);
  providers = $state<string[]>([]);
  loading = $state(false);
  lastError = $state<string | null>(null);

  /** Set by every mutating method; cleared by `restartSidecar()`. The
   *  UI shows a warning chip while this is true. */
  dirty = $state(false);

  async init() {
    await Promise.all([this.refresh(), this.loadProviders()]);
  }

  dispose() {}

  async loadProviders() {
    try {
      this.providers = await invoke<string[]>("keys_known_providers");
    } catch (e) {
      this.lastError = e instanceof Error ? e.message : String(e);
    }
  }

  async refresh() {
    this.loading = true;
    this.lastError = null;
    try {
      this.keys = await invoke<ApiKeyRedacted[]>("keys_list");
    } catch (e) {
      this.lastError = e instanceof Error ? e.message : String(e);
    } finally {
      this.loading = false;
    }
  }

  // Mutations: Rust persists to the keychain + index, then (best-effort)
  // pushes the updated env-var map to the live daemon — the agent sees
  // the new value on its next call. No restart required in the happy path.

  async create(req: KeyCreate): Promise<ApiKeyRedacted> {
    const k = await invoke<ApiKeyRedacted>("keys_create", { req });
    await this.refresh();
    return k;
  }

  async rename(id: string, name: string): Promise<void> {
    await invoke("keys_rename", { req: { id, name } });
    await this.refresh();
  }

  async delete(id: string): Promise<void> {
    await invoke("keys_delete", { id });
    await this.refresh();
  }

  /** Copy the raw secret straight to the OS clipboard. Decryption +
   *  the clipboard write happen entirely inside Rust — the plaintext
   *  never crosses the IPC boundary, so a compromised renderer can't
   *  pull the value via memory inspection or DOM scraping. */
  async copyToClipboard(id: string): Promise<void> {
    await invoke<void>("keys_copy_to_clipboard", { id });
  }

  /** Reveal the raw secret for a single key (user-driven). The plaintext
   *  is read from the keychain in Rust and returned only for this call —
   *  it is never cached in store state. */
  async reveal(id: string): Promise<string> {
    return await invoke<string>("keys_reveal", { id });
  }

  /** Spawn-cycle the Elixir daemon so freshly-saved keys land in its
   *  environment. Clears `dirty` on success. (Name kept stable for the
   *  UI; now wired to the `daemon_restart` command.) */
  async restartSidecar(): Promise<void> {
    await invoke("daemon_restart");
    this.dirty = false;
  }
}

export const keys = new KeysStore();

/** Provider id → env var name. Mirrors the Rust `provider_env_var`
 *  mapping so the UI can show the user what env var their key will be
 *  forwarded as. Custom provider id gets uppercased + `_API_KEY` suffix. */
export function providerEnvVar(
  provider: string,
  customProvider?: string | null,
): string | null {
  const map: Record<string, string> = {
    openrouter: "OPENROUTER_API_KEY",
    anthropic: "ANTHROPIC_API_KEY",
    openai: "OPENAI_API_KEY",
    google: "GOOGLE_API_KEY",
    mistral: "MISTRAL_API_KEY",
    together: "TOGETHER_API_KEY",
    groq: "GROQ_API_KEY",
    cerebras: "CEREBRAS_API_KEY",
    xai: "XAI_API_KEY",
    sambanova: "SAMBANOVA_API_KEY",
    fireworks: "FIREWORKS_API_KEY",
  };
  if (provider === "custom") {
    if (!customProvider?.trim()) return null;
    return `${customProvider.trim().toUpperCase()}_API_KEY`;
  }
  return map[provider] ?? null;
}

/** Display name for a provider id. */
export function providerLabel(provider: string): string {
  const map: Record<string, string> = {
    openrouter: "OpenRouter",
    anthropic: "Anthropic",
    openai: "OpenAI",
    google: "Google",
    mistral: "Mistral",
    together: "Together",
    groq: "Groq",
    cerebras: "Cerebras",
    xai: "xAI",
    sambanova: "SambaNova",
    fireworks: "Fireworks",
    custom: "Custom",
  };
  return map[provider] ?? provider;
}
