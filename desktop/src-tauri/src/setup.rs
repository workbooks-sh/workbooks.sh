// First-launch setup state.
//
// Tracks which one-time setup steps the user has completed. The
// data lives at `~/Workbooks/Engine/setup.json` — per-machine,
// NOT in the user monorepo (the marker is about THIS machine's
// keychain ACL, not about the user's shareable content).
//
// Currently tracks one step (keychain initialization), but the
// shape is extensible — future steps (e.g. accept-tos, install-
// signing-cert) drop in as new boolean fields.

use std::path::PathBuf;
use serde::{Deserialize, Serialize};
use tokio::fs;

use crate::config_paths::workhorse_root;
use crate::crypto;

const SETUP_FILE: &str = "setup.json";

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct SetupState {
    /// True after the user has clicked through the KeychainOnboarding
    /// splash and the underlying `crypto::load_or_create_key` call
    /// has succeeded. Once true, no future launch shows the splash
    /// even if the keychain ACL is somehow reset.
    #[serde(default)]
    pub keychain_initialized: bool,

    /// ISO8601 UTC timestamp of when keychain_initialized flipped
    /// to true. Useful for debugging "did this user actually
    /// complete onboarding."
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub keychain_initialized_at: Option<String>,
}

fn setup_path() -> PathBuf {
    workhorse_root().join(SETUP_FILE)
}

async fn read_state() -> SetupState {
    match fs::read(setup_path()).await {
        Ok(bytes) => serde_json::from_slice(&bytes).unwrap_or_default(),
        Err(_) => SetupState::default(),
    }
}

async fn write_state(state: &SetupState) -> Result<(), String> {
    let path = setup_path();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .await
            .map_err(|e| format!("mkdir workhorse root: {e}"))?;
    }
    let bytes =
        serde_json::to_vec_pretty(state).map_err(|e| format!("serialise setup state: {e}"))?;
    fs::write(&path, bytes)
        .await
        .map_err(|e| format!("write setup.json: {e}"))?;
    Ok(())
}

fn now_iso8601() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64;
    // Crude: avoid pulling chrono just for this single string. The
    // user-facing UI only needs "did this happen", not millisecond
    // precision.
    format!("{}Z", iso8601_from_secs(now))
}

fn iso8601_from_secs(secs: i64) -> String {
    // Inline mini-formatter — chrono is a heavy dep to pull just
    // for one timestamp. Days since 1970 → year/month/day via the
    // standard civil-day algorithm.
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
    let h = (rem / 3600) as i32;
    let mi = ((rem % 3600) / 60) as i32;
    let s = (rem % 60) as i32;

    // Hinnant's civil_from_days, public domain.
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as i64;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as i32;
    let mo = (if mp < 10 { mp + 3 } else { mp - 9 }) as i32;
    let y = if mo <= 2 { y + 1 } else { y };

    format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}")
}

// ── Tauri commands ─────────────────────────────────────────────────

#[derive(Serialize)]
pub struct SetupStatus {
    pub keychain_initialized: bool,
}

/// Cheap, non-prompting check: returns whether the user has
/// completed the keychain-setup splash. Reads `setup.json` only;
/// does NOT touch the keychain itself. Safe to call on every boot
/// from the frontend's onboarding gate.
#[tauri::command]
pub async fn setup_status() -> Result<SetupStatus, String> {
    let s = read_state().await;
    Ok(SetupStatus {
        keychain_initialized: s.keychain_initialized,
    })
}

/// User clicked "Set Up Secure Storage" on the KeychainOnboarding
/// splash. Triggers the actual keychain prompt by calling into
/// `crypto::ensure_key_exists`, then writes the marker to setup.json
/// so future launches skip the splash.
///
/// Idempotent: if already initialized, returns Ok without re-
/// prompting (the underlying load_or_create_key returns the
/// cached key).
#[tauri::command]
pub async fn setup_initialize_keychain() -> Result<(), String> {
    // tokio::task::spawn_blocking because the keyring crate is
    // synchronous + may block on the OS prompt for arbitrary time.
    tokio::task::spawn_blocking(crypto::ensure_key_exists)
        .await
        .map_err(|e| format!("join blocking: {e}"))??;

    let state = SetupState {
        keychain_initialized: true,
        keychain_initialized_at: Some(now_iso8601()),
    };
    write_state(&state).await?;
    Ok(())
}
