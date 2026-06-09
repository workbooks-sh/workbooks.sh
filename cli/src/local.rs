//! Local verbs — run entirely in the CLI, no runtime needed.
//!
//! - assembly: `bundle` renders the org via the embedded kernel and packs the
//!   same `.wbundle` zip the runtime's `Workbooks.Bundle.ship/4` produces
//!   (workbook.html + vfs.sqlite + manifest.json, format `wbundle/1`);
//!   `unbundle` is the inverse.
//! - provenance: `sign`/`verify` — Ed25519 over canonical JSON with a did:key
//!   issuer, byte-compatible with `Workbooks.Manifest` / `Workbooks.Git`.
//! - orchestration: `publish` ships an ASSEMBLED workbook to a surface
//!   (cloudflare-pages via wrangler, gh-pages via git, self-hosted via HTTP).
//! - `var`: file-backed local variables / secrets.

use crate::io::Io;
use crate::util;
use anyhow::{bail, Context, Result};
use base64::Engine as _;
use sha2::Digest;
use std::io::Write as _;

// ─────────────────────────── assembly ───────────────────────────

/// Resolve the org source: a `.org` file, or a dir containing `workbook.org`
/// (else exactly one `.org` file).
fn find_org(src: &str) -> Result<std::path::PathBuf> {
    let p = std::path::Path::new(src);
    if p.is_file() {
        return Ok(p.to_path_buf());
    }
    let wb = p.join("workbook.org");
    if wb.is_file() {
        return Ok(wb);
    }
    let orgs: Vec<_> = std::fs::read_dir(p)
        .with_context(|| format!("read dir {src}"))?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().map(|e| e == "org").unwrap_or(false))
        .collect();
    match orgs.as_slice() {
        [one] => Ok(one.clone()),
        [] => bail!("no .org source in {src} (want workbook.org)"),
        _ => bail!("multiple .org files in {src} — name one workbook.org or pass it explicitly"),
    }
}

pub fn bundle(io: &dyn Io, src: &str, out: Option<&str>) -> Result<String> {
    let org_path = find_org(src)?;
    let org = String::from_utf8(io.read(&org_path.to_string_lossy())?)?;
    let stem = org_path.file_stem().unwrap_or_default().to_string_lossy().to_string();
    let html = oql::render(&org);

    // diagnostics gate: refuse to assemble a workbook that doesn't lint clean
    let diags = oql::validate(&org);
    if diags != "[]" {
        bail!("source has diagnostics — fix them first (wb lint):\n{diags}");
    }

    // sibling vfs.sqlite travels with the workbook when present
    let vfs = org_path.parent().map(|d| d.join("vfs.sqlite")).filter(|p| p.is_file());

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
        org_path.display(),
        buf.len(),
        if vfs.is_some() { ", with vfs.sqlite" } else { "" }
    ))
}

pub fn unbundle(io: &dyn Io, file: &str, dest: Option<&str>) -> Result<String> {
    let blob = io.read(file)?;
    let dest = dest.map(str::to_string).unwrap_or_else(|| {
        std::path::Path::new(file).file_stem().unwrap_or_default().to_string_lossy().to_string()
    });
    let mut z = zip::ZipArchive::new(std::io::Cursor::new(blob)).context("not a workbook bundle (zip)")?;
    let mut names = Vec::new();
    for i in 0..z.len() {
        let mut f = z.by_index(i)?;
        if !f.is_file() {
            continue;
        }
        let name = f.name().to_string();
        // zip-slip guard: refuse absolute / parent-escaping entries
        if name.starts_with('/') || name.split('/').any(|c| c == "..") {
            bail!("refusing unsafe entry path in bundle: {name}");
        }
        let mut bytes = Vec::new();
        std::io::copy(&mut f, &mut bytes)?;
        let path = format!("{dest}/{name}");
        io.write(&path, &bytes)?;
        names.push(name);
    }
    Ok(format!("unbundled {file} → {dest}/ ({})", names.join(", ")))
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
# `wb publish apply <workbook.html|.wbundle>` ships the ASSEMBLED workbook —
# run `wb bundle` first. Publish is distribution only.
";

fn publish_cfg(io: &dyn Io) -> Result<std::collections::BTreeMap<String, String>> {
    let raw = io.read(PUBLISH_FILE).with_context(|| format!("no {PUBLISH_FILE} — run `wb publish init`"))?;
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
    if workbook.ends_with(".org") {
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
            Ok(format!("wrote {PUBLISH_FILE} — edit it, then `wb publish apply <workbook>`"))
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
                    io.spawn("git", &["-C", &s, "-c", "user.name=wb", "-c", "user.email=wb@workbooks.sh", "commit", "-q", "-m", "wb publish"])?;
                    io.spawn("git", &["-C", &s, "push", "-f", &remote, "gh-pages"])?;
                    cfg.get("PUBLISH_DOMAIN").map(|d| format!("https://{d}")).unwrap_or_else(|| {
                        let (org, repo) = project.split_once('/').unwrap_or(("", &project));
                        format!("https://{org}.github.io/{repo}/")
                    })
                }
                "self-hosted" => {
                    let slug = std::path::Path::new(wb).file_stem().unwrap_or_default().to_string_lossy().to_string();
                    let base = project.trim_end_matches('/');
                    let bearer = std::env::var("WB_PUBLISH_TOKEN").ok();
                    io.http_url("PUT", &format!("{base}/w/{slug}"), Some(&html), bearer.as_deref())?;
                    format!("{base}/w/{slug}")
                }
                _ => unreachable!(),
            };
            let _ = std::fs::remove_dir_all(&stage);
            Ok(format!("published {wb} → {url}"))
        }
        v => bail!("usage: wb publish init|validate|apply <workbook> — got {v}"),
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
            let key = args.get(1).context("usage: wb var set <key> <value> [--secret]")?;
            let val = args.get(2).context("usage: wb var set <key> <value> [--secret]")?;
            let secret = args.iter().any(|a| a == "--secret");
            vars.insert(key.clone(), serde_json::json!({"value": val, "secret": secret}));
            io.write(&vars_path(), serde_json::to_string_pretty(&vars)?.as_bytes())?;
            Ok(format!("set {key}{}", if secret { " (secret)" } else { "" }))
        }
        Some("get") => {
            let key = args.get(1).context("usage: wb var get <key>")?;
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
            let mut tpl = args.get(1).context("usage: wb var ref <template>")?.clone();
            for (k, v) in &vars {
                let val = v["value"].as_str().unwrap_or_default();
                tpl = tpl.replace(&format!("{{{{var:{k}}}}}"), val);
                tpl = tpl.replace(&format!("{{{{secret:{k}}}}}"), val);
            }
            Ok(tpl)
        }
        _ => bail!("usage: wb var set|get|list|ref"),
    }
}
