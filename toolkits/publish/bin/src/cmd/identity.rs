// `wb identity export` / `wb identity import` — move a Workbooks
// Network identity (did:key + private key + WorkOS binding) between
// machines. The use case: "I set up my engine on the laptop; now I
// want the same identity on the desktop so my did + handle don't
// change."
//
// Engine identity lives at <data_root>/Engine/network/identity/
// (`binding.json` + `key.b64` mode 0600). This CLI reads/writes those
// files DIRECTLY — the engine doesn't need to be running. The on-disk
// format is owned by WorkbooksRuntime.Network.Identity; we honor it
// here. Two places knowing the format is acceptable for this scope.
//
// Security: --include-private (export) emits the private key. Treat
// the output like a private key. Pipe to gpg/age if persisting.
// Default export is public-only (did + handle + pubkey) for use cases
// like "share my DID for a friend invite."
//
// wb-8fhk.20.

use anyhow::{anyhow, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

use crate::cli::IdentityCmd;
use crate::daemon::Client;

pub async fn run(cmd: IdentityCmd) -> Result<()> {
    match cmd {
        IdentityCmd::Export { out, include_private } => export(out.as_deref(), include_private),
        IdentityCmd::Import { file, force } => import(&file, force),
        IdentityCmd::Show => show(),
        IdentityCmd::BlueskyLogin { handle, app_password, pds_url } => {
            bluesky_login(&handle, app_password.as_deref(), pds_url.as_deref()).await
        }
        IdentityCmd::BlueskyOauthLogin { handle, pds_url, port, no_open, json, standalone } => {
            // AT Protocol OAuth 2.0 — the modern flow (PKCE + PAR +
            // DPoP). Lives in its own sibling module under `cmd/`
            // because the surface is too large to inline here.
            crate::cmd::bluesky_oauth::login(
                handle.as_deref(),
                pds_url.as_deref(),
                port,
                crate::cmd::bluesky_oauth::LoginOpts { no_open, json, standalone },
            )
            .await
        }
        IdentityCmd::BlueskyLogout => bluesky_logout().await,
        IdentityCmd::EnsureCert { json } => cert_verb("ensure", json),
        IdentityCmd::ShowCert { json } => cert_verb("show", json),
        IdentityCmd::RefreshCert { json } => cert_verb("refresh", json),
        IdentityCmd::GenerateCsr { out, json } => csr_verb(out.as_deref(), json),
    }
}

fn csr_verb(out: Option<&Path>, json: bool) -> Result<()> {
    use std::process::Command;

    let cert_bin = resolve_cert_bin()?;
    let key_b64 = key_file()?;
    if !key_b64.exists() {
        return Err(anyhow!(
            "no engine identity bound — expected {} to exist. \
             Run the engine once or `wb identity import` first.",
            key_b64.display()
        ));
    }
    let csr_path: PathBuf = out
        .map(PathBuf::from)
        .unwrap_or_else(|| identity_dir().expect("identity_dir").join("csr.pem"));

    let mut cmd = Command::new(&cert_bin);
    cmd.arg("csr")
        .arg("--key-b64-file")
        .arg(&key_b64)
        .arg("--cert-out")
        .arg(&csr_path);
    if json {
        cmd.arg("--json");
    }
    let status = cmd
        .status()
        .with_context(|| format!("invoke {}", cert_bin.display()))?;
    if !status.success() {
        return Err(anyhow!("{} csr exited with {}", cert_bin.display(), status));
    }
    Ok(())
}

// Shell to the workbooks-cert binary (lives next to workbooks-c2pa-sign
// in the manifest crate). Resolves the binary via:
//   1. WB_C2PA_CERT_BIN env var (canonical for deploy + tests)
//   2. PATH lookup via `which`
//   3. Co-located target/debug/release fallback for dev (mirrors the
//      workbooks-c2pa-sign resolver in Network.Manifest.Spec)
//
// Passes --key-b64-file <key.b64> so workbooks-cert reads the engine
// identity directly — no temp files, no key handling in this process.
fn cert_verb(verb: &str, json: bool) -> Result<()> {
    use std::process::Command;

    let cert_bin = resolve_cert_bin()?;
    let key_b64 = key_file()?;
    let cert_path = identity_dir()?.join("cert.pem");

    if !key_b64.exists() {
        return Err(anyhow!(
            "no engine identity bound — expected {} to exist. \
             Run the engine once or `wb identity import` first.",
            key_b64.display()
        ));
    }

    let mut cmd = Command::new(&cert_bin);
    cmd.arg(verb).arg("--key-b64-file").arg(&key_b64);
    match verb {
        "ensure" | "refresh" => {
            cmd.arg("--cert-out").arg(&cert_path);
        }
        "show" => {
            cmd.arg("--cert-in").arg(&cert_path);
        }
        _ => return Err(anyhow!("unknown cert verb: {verb}")),
    }
    if json {
        cmd.arg("--json");
    }

    let status = cmd
        .status()
        .with_context(|| format!("invoke {}", cert_bin.display()))?;
    if !status.success() {
        return Err(anyhow!("{} {verb} exited with {}", cert_bin.display(), status));
    }
    Ok(())
}

fn resolve_cert_bin() -> Result<PathBuf> {
    if let Ok(p) = std::env::var("WB_C2PA_CERT_BIN") {
        if !p.is_empty() {
            return Ok(PathBuf::from(p));
        }
    }
    if let Ok(p) = which::which("workbooks-cert") {
        return Ok(p);
    }
    // Dev fallback — mirror Network.Manifest.Spec's binary resolver.
    // Look in workspace target/{debug,release}/ relative to the running
    // wb binary, then bail with a clear instruction.
    let exe = std::env::current_exe().ok();
    if let Some(exe) = exe {
        if let Some(dir) = exe.parent() {
            let candidate = dir.join("workbooks-cert");
            if candidate.is_file() {
                return Ok(candidate);
            }
        }
    }
    Err(anyhow!(
        "workbooks-cert not found. Build it with: \
         cargo build --features spec-c2pa -p workbooks-manifest --bin workbooks-cert. \
         Or set WB_C2PA_CERT_BIN to the binary path."
    ))
}

// ── Export ────────────────────────────────────────────────────────

#[derive(Serialize, Deserialize, Debug)]
struct ExportEnvelope {
    /// Bumped if/when the shape changes incompatibly.
    version: u32,
    #[serde(default)]
    exported_at: String,
    /// did:key:z… — same format the engine + atproto-bridging code use.
    did: Option<String>,
    /// @handle (Workbooks Network) — may be nil on a fresh mint.
    handle: Option<String>,
    /// WorkOS user id — binding to a hosted account (optional).
    workos_user_id: Option<String>,
    /// Base64 of the 32-byte Ed25519 public key.
    public_key_b64: Option<String>,
    /// Base64 of the 32-byte Ed25519 private key. Only present when
    /// the operator opted in via --include-private. ALWAYS sensitive.
    #[serde(skip_serializing_if = "Option::is_none")]
    private_key_b64: Option<String>,
}

fn export(out: Option<&Path>, include_private: bool) -> Result<()> {
    let binding = read_binding()?;
    let private = if include_private { read_private_key().ok() } else { None };

    let envelope = ExportEnvelope {
        version: 1,
        exported_at: now_iso8601(),
        did: binding.did,
        handle: binding.handle,
        workos_user_id: binding.workos_user_id,
        public_key_b64: binding.public_b64,
        private_key_b64: private,
    };

    let json = serde_json::to_string_pretty(&envelope)? + "\n";

    match out {
        None => {
            if include_private {
                eprintln!(
                    "warning: --include-private exposes your Ed25519 private key on stdout. \
                     Pipe to `gpg --symmetric` or `age -p` before persisting."
                );
            }
            print!("{json}");
        }
        Some(path) => {
            // Refuse to overwrite — accidental clobbers of an export are
            // operator surprises waiting to happen.
            if path.exists() {
                return Err(anyhow!(
                    "{} already exists — refusing to overwrite",
                    path.display()
                ));
            }
            std::fs::write(path, &json)
                .with_context(|| format!("writing export to {}", path.display()))?;
            // 0600 if we exported the private key — same mode as key.b64.
            if include_private {
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    let mut perms = std::fs::metadata(path)?.permissions();
                    perms.set_mode(0o600);
                    let _ = std::fs::set_permissions(path, perms);
                }
            }
            eprintln!("identity exported to {}{}",
                path.display(),
                if include_private { " (private key INCLUDED, mode 0600)" } else { " (public-only)" }
            );
        }
    }

    Ok(())
}

// ── Import ────────────────────────────────────────────────────────

fn import(file: &Path, force: bool) -> Result<()> {
    let bytes = std::fs::read(file).with_context(|| format!("reading {}", file.display()))?;
    let envelope: ExportEnvelope =
        serde_json::from_slice(&bytes).with_context(|| format!("parsing {} as JSON envelope", file.display()))?;

    if envelope.version != 1 {
        return Err(anyhow!(
            "import envelope version {} not supported (expected 1)",
            envelope.version
        ));
    }

    let did = envelope.did.as_deref().ok_or_else(|| anyhow!("envelope missing :did"))?;
    let pub_b64 = envelope
        .public_key_b64
        .as_deref()
        .ok_or_else(|| anyhow!("envelope missing :public_key_b64"))?;
    let priv_b64 = envelope
        .private_key_b64
        .as_deref()
        .ok_or_else(|| anyhow!("envelope missing :private_key_b64 (export with --include-private)"))?;

    let identity_dir = identity_dir()?;
    let binding_path = identity_dir.join("binding.json");
    let key_path = identity_dir.join("key.b64");

    if (binding_path.exists() || key_path.exists()) && !force {
        return Err(anyhow!(
            "an identity already exists at {} — pass --force to overwrite \
             (you'll lose the existing did + private key permanently)",
            identity_dir.display()
        ));
    }

    std::fs::create_dir_all(&identity_dir)
        .with_context(|| format!("creating {}", identity_dir.display()))?;

    // binding.json — same shape Network.Identity writes (string keys, no
    // pretty-print needed since the engine round-trips through Jason).
    let binding_json = serde_json::json!({
        "did": did,
        "handle": envelope.handle,
        "workos_user_id": envelope.workos_user_id,
        "public_b64": pub_b64,
    });
    std::fs::write(&binding_path, serde_json::to_string(&binding_json)? + "\n")
        .with_context(|| format!("writing {}", binding_path.display()))?;

    // key.b64 — raw base64 with no trailing newline (matches what the
    // engine's Identity.write_key/1 emits, modulo Erlang's :base64.encode/1
    // not adding a newline either).
    std::fs::write(&key_path, priv_b64)
        .with_context(|| format!("writing {}", key_path.display()))?;

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = std::fs::metadata(&key_path)?.permissions();
        perms.set_mode(0o600);
        let _ = std::fs::set_permissions(&key_path, perms);
    }

    println!("identity imported");
    println!("  did:    {did}");
    if let Some(handle) = envelope.handle.as_deref() {
        println!("  handle: {handle}");
    }
    println!("  files:");
    println!("    {} (mode 0600)", key_path.display());
    println!("    {}", binding_path.display());
    println!();
    println!("if an engine is running against this data root, restart it to pick up the new identity");
    Ok(())
}

// ── Show ──────────────────────────────────────────────────────────

fn show() -> Result<()> {
    match read_binding() {
        Ok(b) => {
            println!("did:           {}", b.did.as_deref().unwrap_or("(not minted)"));
            println!("handle:        {}", b.handle.as_deref().unwrap_or("(unbound)"));
            println!("workos_user:   {}", b.workos_user_id.as_deref().unwrap_or("(unbound)"));
            println!("public_key:    {}", b.public_b64.as_deref().unwrap_or("(missing)"));
            // wb-8fhk Bluesky-as-IdP: surface the bound Bluesky identity
            // when present, alongside the engine's did:key.
            match (b.bluesky_did.as_deref(), b.bluesky_handle.as_deref()) {
                (Some(did), Some(handle)) => {
                    println!("bluesky_did:   {did}");
                    println!("bluesky_handle: @{handle}");
                }
                _ => {
                    println!("bluesky:       (unbound — run `wb identity bluesky-login <handle>`)");
                }
            }
            println!("binding.json:  {}", binding_file()?.display());
            Ok(())
        }
        Err(e) => {
            eprintln!("no identity bound yet ({}) — mint via the engine's first start, or `wb identity import`", e);
            Ok(())
        }
    }
}

// ── Bluesky binding (wb-8fhk Bluesky-as-IdP) ─────────────────────

async fn bluesky_login(
    handle: &str,
    app_password_arg: Option<&str>,
    pds_url: Option<&str>,
) -> Result<()> {
    let password = resolve_password(app_password_arg)?;

    // Normalize handle: strip leading @ (users routinely paste @alice.bsky.social).
    let handle = handle.trim_start_matches('@');

    let client = Client::connect()?;
    let mut body = json!({"handle": handle, "app_password": password});
    if let Some(url) = pds_url {
        body.as_object_mut().unwrap().insert("pds_url".into(), Value::String(url.into()));
    }

    let resp: Value = client.post_json("/api/network/atproto/bind", &body).await?;

    if resp.get("ok").and_then(Value::as_bool) != Some(true) {
        return Err(anyhow!(
            "engine rejected the bind: {}",
            resp.get("detail").and_then(Value::as_str).unwrap_or("(no detail)")
        ));
    }

    let binding = resp.get("binding").ok_or_else(|| anyhow!("missing `binding` in response"))?;
    let did = binding.get("did").and_then(Value::as_str).unwrap_or("?");
    let bound_handle = binding.get("handle").and_then(Value::as_str).unwrap_or("?");

    println!("✓ bound to Bluesky");
    println!("  handle: @{bound_handle}");
    println!("  did:    {did}");
    println!();
    println!("The engine will now use this identity for atproto publish + handle resolution.");
    println!("Forget the binding any time with: wb identity bluesky-logout");
    Ok(())
}

async fn bluesky_logout() -> Result<()> {
    let client = Client::connect()?;
    let resp: Value = client.delete_json("/api/network/atproto/binding").await?;

    if resp.get("ok").and_then(Value::as_bool) == Some(true) {
        println!("✓ Bluesky binding cleared (engine's did:key + private key untouched)");
        Ok(())
    } else {
        Err(anyhow!("engine rejected the unbind: {resp}"))
    }
}

fn resolve_password(arg: Option<&str>) -> Result<String> {
    if let Some(p) = arg {
        return Ok(p.to_string());
    }

    if let Ok(p) = std::env::var("WB_BSKY_APP_PASSWORD") {
        if !p.is_empty() {
            return Ok(p);
        }
    }

    // Non-tty (piped) → read raw line from stdin. tty → prompt without echo.
    use std::io::IsTerminal;
    if std::io::stdin().is_terminal() {
        rpassword::prompt_password("Bluesky app password (mint at bsky.app/settings/app-passwords): ")
            .context("reading app password from tty")
    } else {
        use std::io::BufRead;
        let stdin = std::io::stdin();
        let mut line = String::new();
        stdin.lock().read_line(&mut line).context("reading app password from stdin")?;
        Ok(line.trim().to_string())
    }
}

// ── Internal: read on-disk binding files ──────────────────────────

#[derive(Deserialize, Debug)]
struct Binding {
    did: Option<String>,
    handle: Option<String>,
    workos_user_id: Option<String>,
    public_b64: Option<String>,
    bluesky_did: Option<String>,
    bluesky_handle: Option<String>,
}

fn read_binding() -> Result<Binding> {
    let path = binding_file()?;
    let bytes = std::fs::read(&path)
        .with_context(|| format!("reading binding from {}", path.display()))?;
    let b: Binding =
        serde_json::from_slice(&bytes).with_context(|| format!("parsing {}", path.display()))?;
    Ok(b)
}

fn read_private_key() -> Result<String> {
    let path = key_file()?;
    let s = std::fs::read_to_string(&path)
        .with_context(|| format!("reading private key from {}", path.display()))?;
    Ok(s.trim().to_string())
}

fn data_root() -> Result<PathBuf> {
    if let Ok(p) = std::env::var("WB_DATA_ROOT") {
        return Ok(PathBuf::from(p));
    }
    let home = dirs::home_dir().ok_or_else(|| anyhow!("no home directory"))?;
    Ok(home.join("Workbooks"))
}

fn identity_dir() -> Result<PathBuf> {
    Ok(data_root()?.join("Engine").join("network").join("identity"))
}

fn binding_file() -> Result<PathBuf> {
    Ok(identity_dir()?.join("binding.json"))
}

fn key_file() -> Result<PathBuf> {
    Ok(identity_dir()?.join("key.b64"))
}

fn now_iso8601() -> String {
    use time::{format_description::well_known::Rfc3339, OffsetDateTime};
    OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .unwrap_or_else(|_| "1970-01-01T00:00:00Z".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    // Tests share process-wide WB_DATA_ROOT env state — serialize them
    // so cargo's parallel runner doesn't have them stomp on each other.
    static ENV_LOCK: Mutex<()> = Mutex::new(());

    fn isolated_dr() -> (tempfile::TempDir, std::sync::MutexGuard<'static, ()>) {
        let guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("WB_DATA_ROOT", dir.path());
        std::fs::create_dir_all(dir.path().join("Engine/network/identity")).unwrap();
        (dir, guard)
    }

    fn write_binding(dr: &Path, did: &str, handle: Option<&str>) {
        let id = dr.join("Engine/network/identity");
        let binding = serde_json::json!({
            "did": did, "handle": handle, "workos_user_id": null,
            "public_b64": "AAAA"
        });
        std::fs::write(id.join("binding.json"), serde_json::to_string(&binding).unwrap()).unwrap();
        std::fs::write(id.join("key.b64"), "BBBB").unwrap();
    }

    #[test]
    fn export_public_only_excludes_private_key() {
        let (dr, _guard) = isolated_dr();
        write_binding(dr.path(), "did:key:zAlice", Some("@alice"));

        let out = dr.path().join("export.json");
        export(Some(&out), false).unwrap();

        let json: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&out).unwrap()).unwrap();
        assert_eq!(json["did"], "did:key:zAlice");
        assert_eq!(json["handle"], "@alice");
        assert!(json.get("private_key_b64").is_none(), "private key leaked into public export");
    }

    #[test]
    fn export_include_private_round_trips_via_import() {
        let (src, _guard) = isolated_dr();
        write_binding(src.path(), "did:key:zBob", Some("@bob"));
        let bundle = src.path().join("bob.json");
        export(Some(&bundle), true).unwrap();

        let dst = tempfile::tempdir().unwrap();
        std::env::set_var("WB_DATA_ROOT", dst.path());

        import(&bundle, false).unwrap();

        let imported: serde_json::Value = serde_json::from_slice(
            &std::fs::read(dst.path().join("Engine/network/identity/binding.json")).unwrap(),
        )
        .unwrap();
        assert_eq!(imported["did"], "did:key:zBob");
        assert_eq!(imported["handle"], "@bob");
        assert_eq!(
            std::fs::read_to_string(dst.path().join("Engine/network/identity/key.b64")).unwrap(),
            "BBBB"
        );
    }

    #[test]
    fn import_refuses_to_clobber_existing_identity_without_force() {
        let (dr, _guard) = isolated_dr();
        write_binding(dr.path(), "did:key:zPrior", None);

        // Export the existing one (with private) to a bundle, then try to
        // import it back — should refuse without --force even though the
        // contents match.
        let bundle = dr.path().join("self.json");
        export(Some(&bundle), true).unwrap();

        let err = import(&bundle, false).unwrap_err().to_string();
        assert!(err.contains("--force"), "unexpected: {err}");

        // With --force it succeeds.
        import(&bundle, true).unwrap();
    }

    #[test]
    fn import_rejects_envelope_without_private_key() {
        let (dr, _guard) = isolated_dr();
        write_binding(dr.path(), "did:key:zSrc", None);
        let bundle = dr.path().join("no-priv.json");
        export(Some(&bundle), false).unwrap();

        let dst = tempfile::tempdir().unwrap();
        std::env::set_var("WB_DATA_ROOT", dst.path());

        let err = import(&bundle, false).unwrap_err().to_string();
        assert!(err.contains("private_key_b64"), "unexpected: {err}");
    }

    #[test]
    fn import_rejects_unknown_envelope_version() {
        let (dr, _guard) = isolated_dr();
        let bundle = dr.path().join("future.json");
        std::fs::write(
            &bundle,
            serde_json::json!({"version": 99, "did": "did:key:zX"}).to_string(),
        )
        .unwrap();
        let err = import(&bundle, true).unwrap_err().to_string();
        assert!(err.contains("version 99"), "unexpected: {err}");
    }
}
