// Lifecycle bridge — first-run / keychain probe.
//
// Phase B LOCK: the onboarding-flag surface is owned by `setup_*`, and
// the keychain probe is FOLDED IN (no separate keychain_status /
// keychain_init). One probe (setup_status), one init
// (setup_initialize_keychain). Flow:
//   setup_status → setup_initialize_keychain → setup_save_model_key
//   → setup_complete_first_run
//
// All NATIVE / offline (setup.rs, ~/.oql/desktop/setup.json + OS keychain).
// Exported names stay stable for the splash; bodies invoke() the
// canonical commands.

import { invoke } from "@tauri-apps/api/core";

/** Full setup surface (setup.rs SetupStatus, camelCase serde). */
export interface SetupStatus {
  keychain_initialized: boolean;
  has_model_key: boolean;
  first_run_done: boolean;
}

/** Redacted key metadata returned after saving the first model key. */
export interface ApiKeyRedacted {
  id: string;
  name: string;
  provider: string;
  redacted: string;
  created_at: number;
}

/** Args for the first model key (mirrors keychain::KeyCreate). */
export interface SaveModelKeyRequest {
  name: string;
  provider: string;
  custom_provider?: string | null;
  value: string;
}

/** Cheap, non-prompting probe. Reads setup.json + a keychain reachability
 *  check. The splash gates on `keychain_initialized`. */
export async function setupStatus(): Promise<SetupStatus> {
  return await invoke<SetupStatus>("setup_status");
}

/** Trigger the OS keychain prompt (idempotent). Marks the keychain init
 *  flag. The folded keychain_init. */
export async function setupInitializeKeychain(): Promise<void> {
  return await invoke<void>("setup_initialize_keychain");
}

/** Persist the user's first model key during onboarding (keychain insert
 *  + flips has_model_key). */
export async function setupSaveModelKey(
  req: SaveModelKeyRequest,
): Promise<ApiKeyRedacted> {
  return await invoke<ApiKeyRedacted>("setup_save_model_key", { req });
}

/** Mark first-run finished — splash stops gating after this. */
export async function setupCompleteFirstRun(): Promise<void> {
  return await invoke<void>("setup_complete_first_run");
}
