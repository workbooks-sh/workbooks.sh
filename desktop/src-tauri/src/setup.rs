// First-run gate. Folds the former keychain_status + keychain_init commands
// into one canonical surface: probe whether the OS keychain is usable (no
// prompt), whether a model key is saved, and whether the user has finished
// first-run. setup.json holds the two booleans we own; the model-key flag is
// derived from the keychain probe + the persisted hint.

use crate::keychain;
use crate::paths;
use keyring::Entry;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

const PROBE_SERVICE: &str = "sh.workbooks.setup";
const PROBE_ACCOUNT: &str = "probe";

fn setup_path() -> PathBuf {
    paths::oql_desktop_dir().join("setup.json")
}

#[derive(Serialize, Deserialize, Default, Clone)]
struct SetupState {
    keychain_initialized: bool,
    has_model_key: bool,
    first_run_done: bool,
}

fn load() -> SetupState {
    paths::read_json(&setup_path())
}
fn save(s: &SetupState) -> Result<(), String> {
    paths::write_json(&setup_path(), s)
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SetupStatus {
    pub keychain_initialized: bool,
    pub has_model_key: bool,
    pub first_run_done: bool,
}

/// Non-prompting probe: try to READ the probe entry. A NoEntry means the
/// keychain is reachable but uninitialised; any other error means unusable.
fn keychain_reachable() -> bool {
    match Entry::new(PROBE_SERVICE, PROBE_ACCOUNT) {
        Ok(e) => !matches!(e.get_password(), Err(keyring::Error::PlatformFailure(_))),
        Err(_) => false,
    }
}

#[tauri::command]
pub fn setup_status() -> SetupStatus {
    let state = load();
    // has_model_key is authoritative from the persisted hint OR a live probe of
    // the keys index (so an externally-added key still counts).
    let has_key = state.has_model_key || !keychain::keys_list().is_empty();
    SetupStatus {
        keychain_initialized: state.keychain_initialized && keychain_reachable(),
        has_model_key: has_key,
        first_run_done: state.first_run_done,
    }
}

/// Trigger the OS keychain prompt by WRITING the probe entry. Idempotent —
/// re-running just re-sets the same value. Marks keychain_initialized.
#[tauri::command]
pub fn setup_initialize_keychain() -> Result<(), String> {
    let entry = Entry::new(PROBE_SERVICE, PROBE_ACCOUNT).map_err(|e| e.to_string())?;
    entry.set_password("ok").map_err(|e| e.to_string())?;
    let mut s = load();
    s.keychain_initialized = true;
    save(&s)
}

#[tauri::command]
pub fn setup_complete_first_run() -> Result<(), String> {
    let mut s = load();
    s.first_run_done = true;
    save(&s)
}

/// Save the user's first model key during onboarding. Reuses the keychain key
/// insert + flips has_model_key.
#[tauri::command]
pub fn setup_save_model_key(req: keychain::KeyCreate) -> Result<keychain::ApiKeyRedacted, String> {
    // Resolve the provider's env var up front so an unknown provider fails fast
    // before we touch the keychain (the runtime forwards the key under this).
    keychain::provider_env_var(&req.provider, req.custom_provider.as_deref())
        .ok_or_else(|| format!("unknown provider: {}", req.provider))?;
    let redacted = keychain::insert_key(req)?;
    let mut s = load();
    s.has_model_key = true;
    save(&s)?;
    Ok(redacted)
}
