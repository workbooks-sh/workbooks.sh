// Frontend bridge for first-launch setup state.
//
// Two Tauri commands, both backed by `apps/desktop/src-tauri/src/setup.rs`:
//
//   setup_status              cheap, non-prompting. Returns whether
//                             keychain has been initialized.
//   setup_initialize_keychain triggers the OS keychain prompt
//                             (when the user clicks "Set Up Secure
//                             Storage" on the splash). Idempotent.

import { invoke } from "@tauri-apps/api/core";

export interface SetupStatus {
  keychain_initialized: boolean;
}

export async function setupStatus(): Promise<SetupStatus> {
  return await invoke<SetupStatus>("setup_status");
}

export async function setupInitializeKeychain(): Promise<void> {
  return await invoke<void>("setup_initialize_keychain");
}
