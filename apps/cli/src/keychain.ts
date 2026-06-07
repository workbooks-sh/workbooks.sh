// OS-keychain wrapper. Uses macOS Keychain / Windows Credential Vault /
// Linux libsecret via keytar. Falls back to a plaintext file at
// ~/.config/brandnana/credentials.json if the native module fails to load
// (some Linux installs without libsecret). The fallback warns on first
// write so the user knows their key is on disk.

import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

const SERVICE = "brandnana";
const ACCOUNT = "default";

type Keytar = {
  getPassword(service: string, account: string): Promise<string | null>;
  setPassword(service: string, account: string, password: string): Promise<void>;
  deletePassword(service: string, account: string): Promise<boolean>;
};

let keytarPromise: Promise<Keytar | null> | undefined;

function loadKeytar(): Promise<Keytar | null> {
  if (!keytarPromise) {
    keytarPromise = import("keytar").then((m) => (m.default ?? m) as Keytar).catch(() => null);
  }
  return keytarPromise;
}

function fallbackPath(): string {
  const base = process.env.XDG_CONFIG_HOME ?? join(homedir(), ".config");
  return join(base, "brandnana", "credentials.json");
}

interface FallbackStore {
  api_key?: string;
}

function readFallback(): FallbackStore {
  try {
    return JSON.parse(readFileSync(fallbackPath(), "utf8")) as FallbackStore;
  } catch {
    return {};
  }
}

function writeFallback(store: FallbackStore): void {
  const path = fallbackPath();
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, JSON.stringify(store, null, 2), { mode: 0o600 });
}

export async function getApiKey(): Promise<string | null> {
  const kt = await loadKeytar();
  if (kt) {
    return await kt.getPassword(SERVICE, ACCOUNT);
  }
  return readFallback().api_key ?? null;
}

export async function setApiKey(key: string): Promise<{ storage: "keychain" | "file" }> {
  const kt = await loadKeytar();
  if (kt) {
    await kt.setPassword(SERVICE, ACCOUNT, key);
    return { storage: "keychain" };
  }
  writeFallback({ api_key: key });
  return { storage: "file" };
}

export async function deleteApiKey(): Promise<boolean> {
  const kt = await loadKeytar();
  if (kt) {
    return await kt.deletePassword(SERVICE, ACCOUNT);
  }
  writeFallback({});
  return true;
}

export function fallbackLocation(): string {
  return fallbackPath();
}
