//! Local verbs — run entirely in the CLI, no runtime needed.
//!
//! - assembly: `bundle` takes the workbook HTML (passthrough — a workbook IS HTML)
//!   and packs the same `.wbundle` zip the runtime's `Workbooks.Bundle.ship/4`
//!   produces (workbook.html + vfs.sqlite + manifest.json, format `wbundle/1`);
//!   `unbundle` is the inverse.
//! - provenance: `sign`/`verify` — Ed25519 over canonical JSON with a did:key
//!   issuer, byte-compatible with `Workbooks.Manifest` / `Workbooks.Git`.
//! - orchestration: `publish` ships an ASSEMBLED workbook to a surface
//!   (cloudflare-pages via wrangler, gh-pages via git, self-hosted via HTTP).
//! - `var`: file-backed local variables / secrets.

use crate::io::Io;
use crate::util;
use crate::workbook;
use anyhow::{bail, Context, Result};
use base64::Engine as _;
use sha2::Digest;
use std::io::Write as _;

// ─────────────────────────── assembly ───────────────────────────

/// Resolve the workbook source: a source file, or a dir containing the workbook
/// HTML (`index.html`/`workbook.html`, else exactly one `.html` file).
pub(crate) fn find_org(src: &str) -> Result<std::path::PathBuf> {
    let p = std::path::Path::new(src);
    if p.is_file() {
        return Ok(p.to_path_buf());
    }
    for name in ["index.html", "workbook.html"] {
        let wb = p.join(name);
        if wb.is_file() {
            return Ok(wb);
        }
    }
    let srcs: Vec<_> = std::fs::read_dir(p)
        .with_context(|| format!("read dir {src}"))?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| {
            p.extension()
                .map(|e| e == "html" || e == "htm")
                .unwrap_or(false)
        })
        .collect();
    match srcs.as_slice() {
        [one] => Ok(one.clone()),
        [] => bail!("no workbook HTML in {src} (want index.html)"),
        _ => bail!("multiple .html files in {src} — name one index.html or pass it explicitly"),
    }
}

pub fn bundle(io: &dyn Io, src: &str, out: Option<&str>) -> Result<String> {
    let src_path = find_org(src)?;
    let source = String::from_utf8(io.read(&src_path.to_string_lossy())?)?;
    let stem = src_path.file_stem().unwrap_or_default().to_string_lossy().to_string();
    // A workbook IS HTML — render is passthrough (the browser + work-* Lit
    // components do the visual render).
    let html = workbook::render(&source);

    // diagnostics gate: refuse to assemble a workbook that doesn't lint clean
    let diags = workbook::validate(&source);
    if diags != "[]" {
        bail!("source has diagnostics — fix them first (wb lint):\n{diags}");
    }

    // sibling vfs.sqlite travels with the workbook when present
    let vfs = src_path.parent().map(|d| d.join("vfs.sqlite")).filter(|p| p.is_file());

    let manifest = serde_json::json!({
        "id": stem,
        "format": "wbundle/1",
        "volumes": [],
        "signed": false,
        "private_included": false,
        "created": util::unix_now(),
    });

    let out_path = out.map(str::to_string).unwrap_or_else(|| format!("{stem}.wbundle"));
    let mut buf = Vec::new();
    {
        let mut z = zip::ZipWriter::new(std::io::Cursor::new(&mut buf));
        let o = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Deflated);
        z.start_file("workbook.html", o)?;
        z.write_all(html.as_bytes())?;
        // source travels with the artifact — recipients can unbundle + re-author
        z.start_file("workbook.work", o)?;
        z.write_all(source.as_bytes())?;
        if let Some(v) = &vfs {
            z.start_file("vfs.sqlite", o)?;
            z.write_all(&io.read(&v.to_string_lossy())?)?;
        }
        z.start_file("manifest.json", o)?;
        z.write_all(serde_json::to_string(&manifest)?.as_bytes())?;
        z.finish()?;
    }
    io.write(&out_path, &buf)?;
    Ok(format!(
        "bundled {} → {out_path} ({} bytes{})",
        src_path.display(),
        buf.len(),
        if vfs.is_some() { ", with vfs.sqlite" } else { "" }
    ))
}

pub fn unbundle(io: &dyn Io, file: &str, dest: Option<&str>) -> Result<String> {
    let blob = io.read(file)?;
    let dest = dest.map(str::to_string).unwrap_or_else(|| {
        std::path::Path::new(file).file_stem().unwrap_or_default().to_string_lossy().to_string()
    });
    let n = unzip_bytes_to(io, &blob, &dest)?;
    Ok(format!("unbundled {file} → {dest}/ ({n} files)"))
}

/// Extract a zip blob into `dest` (zip-slip guarded). Returns the file count.
/// Shared by `unbundle` and `checkout` (bytes-over-RCP).
pub fn unzip_bytes_to(io: &dyn Io, blob: &[u8], dest: &str) -> Result<usize> {
    let mut z = zip::ZipArchive::new(std::io::Cursor::new(blob)).context("not a workbook bundle (zip)")?;
    let mut count = 0;
    for i in 0..z.len() {
        let mut f = z.by_index(i)?;
        if !f.is_file() {
            continue;
        }
        let name = f.name().to_string();
        if name.starts_with('/') || name.split('/').any(|c| c == "..") {
            bail!("refusing unsafe entry path in bundle: {name}");
        }
        let mut bytes = Vec::new();
        std::io::copy(&mut f, &mut bytes)?;
        io.write(&format!("{dest}/{name}"), &bytes)?;
        count += 1;
    }
    Ok(count)
}

/// Zip a directory tree (relative entry names). Shared by `checkin`.
pub fn zip_dir(io: &dyn Io, dir: &str) -> Result<Vec<u8>> {
    fn walk(root: &std::path::Path, dir: &std::path::Path, out: &mut Vec<(String, std::path::PathBuf)>) -> Result<()> {
        for e in std::fs::read_dir(dir)? {
            let p = e?.path();
            if p.is_dir() {
                walk(root, &p, out)?;
            } else if p.is_file() {
                let rel = p.strip_prefix(root).unwrap().to_string_lossy().replace('\\', "/");
                out.push((rel, p));
            }
        }
        Ok(())
    }
    let root = std::path::Path::new(dir);
    let mut files = Vec::new();
    walk(root, root, &mut files).with_context(|| format!("walk {dir}"))?;
    if files.is_empty() {
        bail!("{dir} has no files to check in");
    }
    let mut buf = Vec::new();
    {
        let mut z = zip::ZipWriter::new(std::io::Cursor::new(&mut buf));
        let o = zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
        for (rel, path) in files {
            z.start_file(rel, o)?;
            z.write_all(&io.read(&path.to_string_lossy())?)?;
        }
        z.finish()?;
    }
    Ok(buf)
}

// ─────────────────────── provenance (sign / verify) ───────────────────────

const TAG_OPEN: &str = r#"<script type="application/workbooks-c2pa+json" id="wb-c2pa-manifest">"#;
const TAG_CLOSE: &str = "</script>";

/// Canonical JSON — recursively key-sorted, compact, UTF-8. The one cross-impl
/// byte contract (matches Workbooks.Manifest.canonical/1).
fn canonical(v: &serde_json::Value) -> String {
    match v {
        serde_json::Value::Object(m) => {
            let mut keys: Vec<_> = m.keys().collect();
            keys.sort();
            let inner: Vec<String> = keys
                .into_iter()
                .map(|k| format!("{}:{}", serde_json::to_string(k).unwrap(), canonical(&m[k])))
                .collect();
            format!("{{{}}}", inner.join(","))
        }
        serde_json::Value::Array(a) => {
            format!("[{}]", a.iter().map(canonical).collect::<Vec<_>>().join(","))
        }
        other => serde_json::to_string(other).unwrap(),
    }
}

/// Remove every embedded manifest block (sign is idempotent, like the Elixir).
fn strip(html: &str) -> String {
    let mut out = String::with_capacity(html.len());
    let mut rest = html;
    while let Some(start) = rest.find(TAG_OPEN) {
        out.push_str(&rest[..start]);
        match rest[start..].find(TAG_CLOSE) {
            Some(endrel) => rest = &rest[start + endrel + TAG_CLOSE.len()..],
            None => {
                rest = &rest[start..];
                break;
            }
        }
    }
    out.push_str(rest);
    out
}

fn sha256_hex(b: &[u8]) -> String {
    let mut h = sha2::Sha256::new();
    h.update(b);
    h.finalize().iter().map(|x| format!("{x:02x}")).collect()
}

/// Load (or mint) the CLI's local Ed25519 signing key — same on-disk format as
/// the runtime keystore (hex seed + hex pub), under the sh.workbooks app dir.
fn signing_key(io: &dyn Io) -> Result<ed25519_dalek::SigningKey> {
    let dir = util::app_dir().join("keys");
    let path = dir.join("local.ed25519");
    if let Ok(hex) = io.read(&path.to_string_lossy()) {
        let hex = String::from_utf8(hex)?;
        let seed = hex_decode(hex.trim())?;
        let seed: [u8; 32] = seed.as_slice().try_into().context("bad key length")?;
        return Ok(ed25519_dalek::SigningKey::from_bytes(&seed));
    }
    let key = ed25519_dalek::SigningKey::generate(&mut rand_core::OsRng);
    io.write(&path.to_string_lossy(), hex_encode(key.as_bytes()).as_bytes())?;
    io.write(
        &(path.to_string_lossy().to_string() + ".pub"),
        hex_encode(key.verifying_key().as_bytes()).as_bytes(),
    )?;
    // private half is a local credential — user-only, like the runtime keystore
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
    }
    Ok(key)
}

fn hex_encode(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}
fn hex_decode(s: &str) -> Result<Vec<u8>> {
    if s.len() % 2 != 0 {
        bail!("odd-length hex");
    }
    (0..s.len()).step_by(2).map(|i| Ok(u8::from_str_radix(&s[i..i + 2], 16)?)).collect()
}

/// did:key for an Ed25519 pubkey: multicodec 0xED01 prefix, base58btc, `z` tag.
fn did_of(pub_key: &[u8; 32]) -> String {
    let mut bytes = vec![0xED, 0x01];
    bytes.extend_from_slice(pub_key);
    format!("did:key:z{}", bs58::encode(bytes).into_string())
}
fn pub_of_did(did: &str) -> Result<[u8; 32]> {
    let b58 = did.strip_prefix("did:key:z").context("not a did:key")?;
    let bytes = bs58::decode(b58).into_vec().context("bad base58 in did")?;
    if bytes.len() != 34 || bytes[0] != 0xED || bytes[1] != 0x01 {
        bail!("not an Ed25519 did:key");
    }
    Ok(bytes[2..].try_into().unwrap())
}

pub fn sign(io: &dyn Io, file: &str, out: Option<&str>) -> Result<String> {
    use ed25519_dalek::Signer;
    let html = String::from_utf8(io.read(file)?)?;
    let stripped = strip(&html);
    let key = signing_key(io)?;
    let did = did_of(key.verifying_key().as_bytes());

    let manifest = serde_json::json!({
        "version": "v1",
        "issuer_did": did,
        "claim_generator": "wb-cli/0.1",
        "issued_at": util::iso_now(),
        "asset_sha256": sha256_hex(stripped.as_bytes()),
        "assertions": [{"type": "c2pa.action.published", "actor": did}],
    });

    let sig = key.sign(canonical(&manifest).as_bytes());
    let sig_b64 = base64::engine::general_purpose::STANDARD.encode(sig.to_bytes());

    let mut full = manifest;
    full["signature"] = serde_json::Value::String(sig_b64);
    let block = format!("{TAG_OPEN}{}{TAG_CLOSE}", serde_json::to_string(&full)?);

    let signed = if let Some(pos) = stripped.find("</body>") {
        format!("{}{}{}", &stripped[..pos], block, &stripped[pos..])
    } else {
        format!("{stripped}{block}")
    };

    let out_path = out.unwrap_or(file);
    io.write(out_path, signed.as_bytes())?;
    Ok(format!("signed {file} as {did} → {out_path}"))
}

pub fn verify(io: &dyn Io, file: &str) -> Result<String> {
    use ed25519_dalek::Verifier;
    let html = String::from_utf8(io.read(file)?)?;

    let start = match html.find(TAG_OPEN) {
        Some(s) => s + TAG_OPEN.len(),
        None => return Ok(r#"{"error":"no manifest"}"#.into()),
    };
    let end = html[start..].find(TAG_CLOSE).map(|e| start + e).context("unterminated manifest block")?;
    let mut full: serde_json::Value = serde_json::from_str(&html[start..end]).context("bad manifest JSON")?;

    let sig_b64 = full
        .as_object_mut()
        .and_then(|m| m.remove("signature"))
        .and_then(|v| v.as_str().map(str::to_string))
        .context("manifest has no signature")?;
    let did = full["issuer_did"].as_str().unwrap_or_default().to_string();

    let sig_ok = (|| -> Result<bool> {
        let pubkey = ed25519_dalek::VerifyingKey::from_bytes(&pub_of_did(&did)?)?;
        let sig_bytes: [u8; 64] = base64::engine::general_purpose::STANDARD
            .decode(&sig_b64)?
            .as_slice()
            .try_into()
            .map_err(|_| anyhow::anyhow!("bad signature length"))?;
        Ok(pubkey.verify(canonical(&full).as_bytes(), &ed25519_dalek::Signature::from_bytes(&sig_bytes)).is_ok())
    })()
    .unwrap_or(false);

    let hash_ok = full["asset_sha256"].as_str().unwrap_or_default() == sha256_hex(strip(&html).as_bytes());

    Ok(serde_json::to_string_pretty(&serde_json::json!({
        "signature": sig_ok,
        "asset_integrity": hash_ok,
        "valid": sig_ok && hash_ok,
        "issuer_did": did,
        "issued_at": full["issued_at"],
        "assertions": full["assertions"],
    }))?)
}

// ─────────────────────────── publish ───────────────────────────

const PUBLISH_FILE: &str = "publish.org";
const PUBLISH_TEMPLATE: &str = "\
#+TITLE: Workbooks publish config
#+PUBLISH_TARGET: cloudflare-pages
#+PUBLISH_PROJECT: my-workbook
# PUBLISH_TARGET:  cloudflare-pages | gh-pages | self-hosted
# PUBLISH_PROJECT: CF Pages project name, GitHub repo (org/name), or runtime URL
# PUBLISH_DOMAIN:  optional custom domain (for the printed URL)
# `wbx publish apply <workbook.html|.wbundle>` ships the ASSEMBLED workbook —
# run `wb bundle` first. Publish is distribution only.
";

fn publish_cfg(io: &dyn Io) -> Result<std::collections::BTreeMap<String, String>> {
    let raw = io.read(PUBLISH_FILE).with_context(|| format!("no {PUBLISH_FILE} — run `wbx publish init`"))?;
    Ok(util::org_keywords(&String::from_utf8(raw)?))
}

fn publish_validate(io: &dyn Io) -> Result<(String, String)> {
    let cfg = publish_cfg(io)?;
    let target = cfg.get("PUBLISH_TARGET").cloned().unwrap_or_default();
    let project = cfg.get("PUBLISH_PROJECT").cloned().unwrap_or_default();
    if !["cloudflare-pages", "gh-pages", "self-hosted"].contains(&target.as_str()) {
        bail!("PUBLISH_TARGET must be cloudflare-pages | gh-pages | self-hosted (got `{target}`)");
    }
    if project.is_empty() {
        bail!("PUBLISH_PROJECT is required");
    }
    Ok((target, project))
}

/// Extract the html to ship: a bare `.html`, or `workbook.html` out of a `.wbundle`.
fn shippable_html(io: &dyn Io, workbook: &str) -> Result<Vec<u8>> {
    if workbook.ends_with(".work") {
        bail!("publish ships ASSEMBLED workbooks — run `wb bundle {workbook}` first");
    }
    let bytes = io.read(workbook)?;
    if workbook.ends_with(".wbundle") {
        let mut z = zip::ZipArchive::new(std::io::Cursor::new(bytes)).context("not a workbook bundle")?;
        let mut f = z.by_name("workbook.html").context("bundle has no workbook.html")?;
        let mut html = Vec::new();
        std::io::copy(&mut f, &mut html)?;
        return Ok(html);
    }
    Ok(bytes)
}

pub fn publish(io: &dyn Io, verb: &str, workbook: Option<&str>) -> Result<String> {
    match verb {
        "init" => {
            if io.read(PUBLISH_FILE).is_ok() {
                bail!("{PUBLISH_FILE} already exists");
            }
            io.write(PUBLISH_FILE, PUBLISH_TEMPLATE.as_bytes())?;
            Ok(format!("wrote {PUBLISH_FILE} — edit it, then `wbx publish apply <workbook>`"))
        }
        "validate" => {
            let (target, project) = publish_validate(io)?;
            Ok(format!("ok — {PUBLISH_FILE} (target={target} project={project})"))
        }
        "apply" => {
            let (target, project) = publish_validate(io)?;
            let cfg = publish_cfg(io)?;
            let wb = workbook.unwrap_or("workbook.html");
            let html = shippable_html(io, wb)?;

            // stage dir: the artifact as index.html
            let stage = std::env::temp_dir().join(format!("wb-publish-{}", util::unix_now()));
            let index = stage.join("index.html");
            io.write(&index.to_string_lossy(), &html)?;

            let url = match target.as_str() {
                "cloudflare-pages" => {
                    io.spawn("wrangler", &["pages", "deploy", &stage.to_string_lossy(), "--project-name", &project, "--commit-dirty=true"])?;
                    cfg.get("PUBLISH_DOMAIN").map(|d| format!("https://{d}")).unwrap_or(format!("https://{project}.pages.dev"))
                }
                "gh-pages" => {
                    let s = stage.to_string_lossy().to_string();
                    let remote = if project.contains("://") || project.starts_with("git@") {
                        project.clone()
                    } else {
                        format!("https://github.com/{project}.git")
                    };
                    io.spawn("git", &["-C", &s, "init", "-q", "-b", "gh-pages"])?;
                    io.spawn("git", &["-C", &s, "add", "-A"])?;
                    io.spawn("git", &["-C", &s, "-c", "user.name=wb", "-c", "user.email=wb@workbooks.sh", "commit", "-q", "-m", "wbx publish"])?;
                    io.spawn("git", &["-C", &s, "push", "-f", &remote, "gh-pages"])?;
                    cfg.get("PUBLISH_DOMAIN").map(|d| format!("https://{d}")).unwrap_or_else(|| {
                        let (org, repo) = project.split_once('/').unwrap_or(("", &project));
                        format!("https://{org}.github.io/{repo}/")
                    })
                }
                "self-hosted" => {
                    let slug = std::path::Path::new(wb).file_stem().unwrap_or_default().to_string_lossy().to_string();
                    let base = project.trim_end_matches('/');
                    let bearer = crate::util::env_var("PUBLISH_TOKEN");
                    io.http_url("PUT", &format!("{base}/w/{slug}"), Some(&html), bearer.as_deref())?;
                    format!("{base}/w/{slug}")
                }
                _ => unreachable!(),
            };
            let _ = std::fs::remove_dir_all(&stage);
            Ok(format!("published {wb} → {url}"))
        }
        v => bail!("usage: wbxx publish init|validate|apply <workbook> — got {v}"),
    }
}

// ─────────────────────────── var ───────────────────────────

fn vars_path() -> String {
    util::app_dir().join("vars.json").to_string_lossy().to_string()
}
fn vars_load(io: &dyn Io) -> serde_json::Map<String, serde_json::Value> {
    io.read(&vars_path())
        .ok()
        .and_then(|b| serde_json::from_slice::<serde_json::Value>(&b).ok())
        .and_then(|v| v.as_object().cloned())
        .unwrap_or_default()
}

pub fn var(io: &dyn Io, args: &[String]) -> Result<String> {
    let mut vars = vars_load(io);
    match args.first().map(String::as_str) {
        Some("set") => {
            let key = args.get(1).context("usage: wbx var set <key> <value> [--secret]")?;
            let val = args.get(2).context("usage: wbx var set <key> <value> [--secret]")?;
            let secret = args.iter().any(|a| a == "--secret");
            vars.insert(key.clone(), serde_json::json!({"value": val, "secret": secret}));
            io.write(&vars_path(), serde_json::to_string_pretty(&vars)?.as_bytes())?;
            Ok(format!("set {key}{}", if secret { " (secret)" } else { "" }))
        }
        Some("get") => {
            let key = args.get(1).context("usage: wbx var get <key>")?;
            match vars.get(key) {
                Some(v) if v["secret"].as_bool().unwrap_or(false) => Ok("(secret — use {{secret:KEY}} refs)".into()),
                Some(v) => Ok(v["value"].as_str().unwrap_or_default().to_string()),
                None => bail!("no such var: {key}"),
            }
        }
        Some("list") => {
            if vars.is_empty() {
                return Ok("(no vars)".into());
            }
            Ok(vars
                .iter()
                .map(|(k, v)| {
                    if v["secret"].as_bool().unwrap_or(false) {
                        format!("{k} = ******")
                    } else {
                        format!("{k} = {}", v["value"].as_str().unwrap_or_default())
                    }
                })
                .collect::<Vec<_>>()
                .join("\n"))
        }
        Some("ref") => {
            let mut tpl = args.get(1).context("usage: wbx var ref <template>")?.clone();
            for (k, v) in &vars {
                let val = v["value"].as_str().unwrap_or_default();
                tpl = tpl.replace(&format!("{{{{var:{k}}}}}"), val);
                tpl = tpl.replace(&format!("{{{{secret:{k}}}}}"), val);
            }
            Ok(tpl)
        }
        _ => bail!("usage: wbx var set|get|list|ref"),
    }
}

// ─────────────────────────── scaffold ───────────────────────────

/// `wbx init <name>` — a new workbook source that lints clean and bundles.
pub fn init(name: &str, template: &str) -> Result<String> {
    if template != "minimal" {
        bail!("unknown template '{template}' (have: minimal)");
    }
    let dir = std::path::Path::new(name);
    if dir.exists() {
        bail!("{name} already exists");
    }
    std::fs::create_dir_all(dir.join("data")).with_context(|| format!("create {name}/data"))?;
    // A workbook IS an HTML file built from `work-*` web components. Prose, data,
    // and code live together as `work-*` elements; the browser + the workponents
    // Lit library render it. A `<work-component>` body is buildable source.
    let src = format!(
        "<!doctype html>\n<html lang=\"en\">\n<head>\n  <meta charset=\"utf-8\">\n  \
         <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n  \
         <title>{name}</title>\n</head>\n<body>\n  \
         <work-flow title=\"{name}\">\n    \
         <p>A new workbook. Prose, data, and code live together as work-* elements —\n    \
         edit it, then preview with <code>wbx dev</code> and assemble with <code>wbx bundle</code>.</p>\n    \
         <work-component title=\"main\" lang=\"javascript\">\n      \
         // code blocks tangle into the workbook\n    \
         </work-component>\n  \
         </work-flow>\n</body>\n</html>\n"
    );
    let src_path = dir.join("index.html");
    std::fs::write(&src_path, &src).with_context(|| format!("write {}", src_path.display()))?;

    // the scaffold must satisfy its own toolchain — refuse to ship a template
    // that doesn't lint clean
    let diags = workbook::validate(&src);
    if diags != "[]" {
        bail!("template bug: scaffold has diagnostics:\n{diags}");
    }
    Ok(format!(
        "{name}/
  index.html  the workbook — prose + tasks + code as work-* elements
  data/       files that travel with it

next: cd {name} && wbx dev"
    ))
}

// ─────────────────────────── ops ───────────────────────────

/// `wbx open <file>` — the default browser, cross-platform.
#[cfg(not(target_arch = "wasm32"))]
pub fn open(file: &str) -> Result<String> {
    let p = std::path::Path::new(file);
    if !p.exists() {
        bail!("not found: {file}");
    }
    let target = p.canonicalize().unwrap_or_else(|_| p.to_path_buf());
    let status = if cfg!(target_os = "macos") {
        std::process::Command::new("open").arg(&target).status()
    } else if cfg!(windows) {
        std::process::Command::new("cmd").args(["/C", "start", ""]).arg(&target).status()
    } else {
        std::process::Command::new("xdg-open").arg(&target).status()
    }
    .context("launch opener")?;
    if !status.success() {
        bail!("opener exited with {status}");
    }
    Ok(format!("opened {}", target.display()))
}

#[cfg(target_arch = "wasm32")]
pub fn open(_file: &str) -> Result<String> {
    bail!("`wbx open` needs the native binary")
}

/// `wbx upgrade` — replace this binary with the latest release.
#[cfg(not(target_arch = "wasm32"))]
pub fn upgrade() -> Result<String> {
    let exe = std::env::current_exe().context("locate current binary")?;
    if exe.components().any(|c| c.as_os_str() == "node_modules") {
        return Ok("installed via npm — upgrade with: npm update -g @work.books/cli".into());
    }
    let repo = crate::util::env_var("CLI_REPO").unwrap_or_else(|| "workbooks-sh/workbooks.sh".into());
    let client = reqwest::blocking::Client::builder()
        .user_agent("wbx-upgrade")
        .build()?;
    let body = client
        .get(format!("https://api.github.com/repos/{repo}/releases?per_page=30"))
        .send()
        .context("query releases")?
        .text()?;
    let rels: serde_json::Value = serde_json::from_str(&body).context("parse releases")?;
    let tag = rels
        .as_array()
        .and_then(|a| {
            a.iter()
                .filter_map(|r| r["tag_name"].as_str())
                .find(|t| t.starts_with("wbx-v"))
        })
        .context("no wbx-v* release found")?
        .to_string();
    let latest = tag.trim_start_matches("wbx-v");
    if latest == env!("CARGO_PKG_VERSION") {
        return Ok(format!("already current: wbx {latest}"));
    }
    let os = if cfg!(target_os = "macos") { "darwin" } else if cfg!(windows) { "windows" } else { "linux" };
    let arch = if cfg!(target_arch = "aarch64") { "arm64" } else { "x64" };
    let ext = if cfg!(windows) { ".exe" } else { "" };
    let url = format!("https://github.com/{repo}/releases/download/{tag}/wbx-{os}-{arch}{ext}");
    let bytes = client.get(&url).send().context("download")?.error_for_status()?.bytes()?;
    let tmp = exe.with_extension("new");
    std::fs::write(&tmp, &bytes).with_context(|| format!("write {}", tmp.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o755))?;
    }
    std::fs::rename(&tmp, &exe).context("swap binary into place")?;
    Ok(format!("upgraded: wbx {} → {latest}", env!("CARGO_PKG_VERSION")))
}

#[cfg(target_arch = "wasm32")]
pub fn upgrade() -> Result<String> {
    bail!("`wbx upgrade` needs the native binary")
}
