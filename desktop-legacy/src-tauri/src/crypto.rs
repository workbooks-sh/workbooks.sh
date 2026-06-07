// At-rest encryption for secret values (api keys, env vars,
// connection tokens). The 256-bit key lives in the OS keychain
// (macOS Keychain / Windows Credential Manager / Linux Secret
// Service) so it never sits on disk in plaintext.
//
// Encrypted blob format on disk:
//
//     "wbenc1:" + base64( nonce[12] || ciphertext )
//
// Prefix marker lets `read_secret_value` detect plaintext from
// pre-encryption installs and silently re-encrypt on the next
// write. AES-256-GCM provides both confidentiality and
// authentication — tampering with the ciphertext fails the GCM tag
// check on decrypt.
//
// The key is generated once per install on first write. Lookup uses
// service `"sh.workbooks.desktop"` + account `"secrets-key-v1"` so
// a future key rotation can land under v2 without overwriting v1.

#![allow(clippy::module_name_repetitions)]

use aes_gcm::aead::{Aead, KeyInit, OsRng};
use aes_gcm::{Aes256Gcm, Key, Nonce};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use once_cell::sync::OnceCell;
use rand::RngCore;

const KEYCHAIN_SERVICE: &str = "sh.workbooks.desktop";
const KEYCHAIN_ACCOUNT: &str = "secrets-key-v1";
const ENC_PREFIX: &str = "wbenc1:";
const KEY_LEN: usize = 32;
const NONCE_LEN: usize = 12;

/// Process-cached cipher so we don't re-fetch from the keychain on
/// every encrypt/decrypt. Initialised on first use.
static CIPHER: OnceCell<Aes256Gcm> = OnceCell::new();

fn keyring_entry() -> Result<keyring::Entry, String> {
    keyring::Entry::new(KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT)
        .map_err(|e| format!("keychain entry: {e}"))
}

/// Fetch the install's secret-encryption key, generating + storing a
/// fresh one on first use. The key is 32 random bytes, base64-encoded
/// in the keychain so the keychain UI displays sensibly.
fn load_or_create_key() -> Result<[u8; KEY_LEN], String> {
    let entry = keyring_entry()?;
    match entry.get_password() {
        Ok(b64) => {
            let bytes = B64
                .decode(b64.as_bytes())
                .map_err(|e| format!("decode keychain key: {e}"))?;
            if bytes.len() != KEY_LEN {
                return Err(format!(
                    "keychain key wrong length: got {}, want {KEY_LEN}",
                    bytes.len()
                ));
            }
            let mut out = [0u8; KEY_LEN];
            out.copy_from_slice(&bytes);
            Ok(out)
        }
        Err(keyring::Error::NoEntry) => {
            let mut k = [0u8; KEY_LEN];
            OsRng.fill_bytes(&mut k);
            let b64 = B64.encode(k);
            entry
                .set_password(&b64)
                .map_err(|e| format!("write keychain key: {e}"))?;
            Ok(k)
        }
        Err(e) => Err(format!("read keychain key: {e}")),
    }
}

/// Tests and headless CI runs don't have an OS keychain. When
/// `OQL_DESKTOP_HOME` is set (which the desktop binary itself never
/// sets — only the test harness does), use a deterministic in-process
/// key so tests can exercise the encrypt/decrypt path without touching
/// the user's real keychain.
fn key_for_tests() -> Option<[u8; KEY_LEN]> {
    if std::env::var_os("OQL_DESKTOP_HOME").is_some() {
        // Deterministic, but only valid inside the test process —
        // since `OQL_DESKTOP_HOME` points at a tempdir, nothing else
        // will ever decrypt these bytes.
        let mut k = [0u8; KEY_LEN];
        for (i, slot) in k.iter_mut().enumerate() {
            *slot = (i as u8).wrapping_mul(7).wrapping_add(13);
        }
        Some(k)
    } else {
        None
    }
}

fn cipher() -> Result<&'static Aes256Gcm, String> {
    CIPHER.get_or_try_init(|| {
        let bytes = match key_for_tests() {
            Some(k) => k,
            None => load_or_create_key()?,
        };
        let key = Key::<Aes256Gcm>::from_slice(&bytes);
        Ok::<_, String>(Aes256Gcm::new(key))
    })
}

/// Deliberately initialize the keychain entry. Called by the
/// `setup_initialize_keychain` Tauri command from the
/// KeychainOnboarding splash, so the OS prompt fires with the
/// splash still visible as context — never as a surprise during
/// boot.
///
/// Idempotent: if the entry already exists + we have ACL access,
/// returns Ok immediately without prompting. If the entry doesn't
/// exist, generates a fresh 32-byte AES-256 key + writes it to
/// the keychain (which triggers the OS prompt).
pub fn ensure_key_exists() -> Result<(), String> {
    // Test path: deterministic in-process key, no OS keychain.
    if key_for_tests().is_some() {
        return Ok(());
    }

    let _ = load_or_create_key()?;
    Ok(())
}

/// Encrypt a plaintext secret. Returns `"wbenc1:" + base64(nonce || ct)`.
pub fn encrypt_value(plaintext: &str) -> Result<String, String> {
    let c = cipher()?;
    let mut nonce_bytes = [0u8; NONCE_LEN];
    OsRng.fill_bytes(&mut nonce_bytes);
    let nonce = Nonce::from_slice(&nonce_bytes);
    let ct = c
        .encrypt(nonce, plaintext.as_bytes())
        .map_err(|e| format!("encrypt: {e}"))?;
    let mut packed = Vec::with_capacity(NONCE_LEN + ct.len());
    packed.extend_from_slice(&nonce_bytes);
    packed.extend_from_slice(&ct);
    Ok(format!("{ENC_PREFIX}{}", B64.encode(packed)))
}

/// Decrypt a stored value. Returns the input unchanged when it lacks
/// the encryption prefix — these are legacy plaintext values from
/// pre-encryption installs. The caller (keys.rs / env_vars.rs) should
/// re-encrypt them on the next write.
pub fn decrypt_value(stored: &str) -> Result<String, String> {
    if !stored.starts_with(ENC_PREFIX) {
        // Pre-encryption plaintext — pass through. Will get encrypted
        // on the next write of this record.
        return Ok(stored.to_string());
    }
    let b64 = &stored[ENC_PREFIX.len()..];
    let packed = B64
        .decode(b64.as_bytes())
        .map_err(|e| format!("decode encrypted blob: {e}"))?;
    if packed.len() <= NONCE_LEN {
        return Err("encrypted blob too short".to_string());
    }
    let (nonce_bytes, ct) = packed.split_at(NONCE_LEN);
    let nonce = Nonce::from_slice(nonce_bytes);
    let c = cipher()?;
    let pt = c
        .decrypt(nonce, ct)
        .map_err(|e| format!("decrypt: {e} (key rotated or blob tampered)"))?;
    String::from_utf8(pt).map_err(|e| format!("decrypted bytes not utf8: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    // These tests hit the real OS keychain. Skip them in CI by default
    // via `--lib -- --skip crypto::tests::roundtrip`; they're useful
    // locally to confirm the keychain wiring on a fresh machine.
    #[test]
    #[ignore]
    fn roundtrip() {
        let s = "sk-test-secret-12345";
        let enc = encrypt_value(s).unwrap();
        assert!(enc.starts_with("wbenc1:"));
        let dec = decrypt_value(&enc).unwrap();
        assert_eq!(dec, s);
    }

    #[test]
    fn plaintext_passes_through() {
        // Legacy values without the prefix pass through untouched.
        let s = "plaintext-legacy-value";
        let dec = decrypt_value(s).unwrap();
        assert_eq!(dec, s);
    }
}
