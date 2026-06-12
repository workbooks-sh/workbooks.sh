//! Stage 2 of the intake ramp: the wasm-compatibility dependency audit
//! (cli/SPEC.md § Import). Static, offline, honest — classifies every carried
//! script and detected dependency against the ecosystem's wasm lanes:
//!
//!   ready        the lane covers it today (posix shell shape, quickjs, …)
//!   convertible  a known recipe exists but needs work (a build, a shim)
//!   blocked      native-only — needs redesign or an engine-side capability
//!
//! Findings are written INTO the toolkit's manifest.org (the artifact carries
//! its own audit), and returned as prose (human) or JSON (agents).

use anyhow::{Context, Result};
use std::path::Path;

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Class {
    Ready,
    Convertible,
    Blocked,
}

impl Class {
    fn s(&self) -> &'static str {
        match self {
            Class::Ready => "ready",
            Class::Convertible => "convertible",
            Class::Blocked => "blocked",
        }
    }
}

pub struct Finding {
    pub name: String,
    pub kind: &'static str, // interpreter | binary | npm | pip | net
    pub class: Class,
    pub note: &'static str,
}

pub struct ScriptAudit {
    pub file: String,
    pub interpreter: String,
    pub class: Class,
    pub findings: Vec<Finding>,
}

/// Interpreter classification against the lanes.
fn classify_interpreter(interp: &str) -> (Class, &'static str) {
    match interp {
        "sh" | "bash" | "zsh" => (Class::Ready, "posix shape — shell runs in the sandbox"),
        "node" | "js" => (Class::Ready, "quickjs lane — most of Node's surface; full-Node APIs may need shims"),
        "python" | "python3" => (Class::Blocked, "no python lane today — rewrite in a covered lane or split the logic"),
        "ruby" | "perl" => (Class::Blocked, "no lane — rewrite in a covered lane"),
        _ => (Class::Convertible, "unknown interpreter — investigate against the lanes"),
    }
}

/// Binary classification: the short list that genuinely can't follow.
fn classify_binary(bin: &str) -> Option<Finding> {
    let (class, note): (Class, &'static str) = match bin {
        "curl" | "wget" => (Class::Convertible, "network is engine-brokered — route through the Dock, not raw sockets"),
        "git" => (Class::Convertible, "git exists engine-side — call through the engine, not a local binary"),
        "jq" => (Class::Ready, "c lane — jq compiles to wasm cleanly"),
        "ffmpeg" => (Class::Ready, "already a shipped toolkit — depend on it instead of bundling"),
        "docker" | "podman" => (Class::Blocked, "container runtimes can't nest in the sandbox — engine territory"),
        "sudo" | "systemctl" | "launchctl" => (Class::Blocked, "host administration — has no sandbox meaning"),
        "osascript" | "open" | "xdg-open" => (Class::Blocked, "host-desktop integration — no sandbox equivalent"),
        "brew" | "apt" | "apt-get" | "yum" => (Class::Blocked, "host package managers — dependencies must compile into the toolkit"),
        "npm" | "npx" | "bun" | "node" => (Class::Convertible, "npm lane exists — resolve/bundle at build time, not install at runtime"),
        "pip" | "pip3" => (Class::Blocked, "no python lane — see interpreter note"),
        _ => return None, // unremarkable or unknown — don't speculate
    };
    Some(Finding { name: bin.into(), kind: "binary", class, note })
}

fn interpreter_of(path: &Path, body: &str) -> String {
    if let Some(first) = body.lines().next() {
        if let Some(rest) = first.strip_prefix("#!") {
            let last = rest.split(['/', ' ']).filter(|s| !s.is_empty()).last().unwrap_or("");
            if last == "env" {
                // "#!/usr/bin/env node" — env eats the real name; take the token after env
                if let Some(tok) = rest.split_whitespace().nth(1) {
                    return tok.to_string();
                }
            }
            if !last.is_empty() {
                return last.to_string();
            }
        }
    }
    match path.extension().and_then(|e| e.to_str()) {
        Some("sh") => "sh".into(),
        Some("js" | "mjs" | "cjs") => "node".into(),
        Some("py") => "python".into(),
        Some("rb") => "ruby".into(),
        other => other.unwrap_or("unknown").into(),
    }
}

fn audit_script(path: &Path) -> Result<ScriptAudit> {
    let body = std::fs::read_to_string(path).with_context(|| format!("read {}", path.display()))?;
    let interp = interpreter_of(path, &body);
    let (iclass, inote) = classify_interpreter(&interp);
    let mut findings = vec![Finding { name: interp.clone(), kind: "interpreter", class: iclass, note: inote }];

    // binaries at command position (shell-ish heuristic; good enough offline)
    let mut seen = std::collections::BTreeSet::new();
    for line in body.lines() {
        let l = line.trim_start();
        if l.starts_with('#') || l.starts_with("//") {
            continue;
        }
        for seg in l.split(['|', ';', '&', '(', '`']) {
            if let Some(word) = seg.trim_start().split_whitespace().next() {
                let w = word.trim_start_matches('$').trim();
                if w.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_') && seen.insert(w.to_string()) {
                    if let Some(f) = classify_binary(w) {
                        findings.push(f);
                    }
                }
            }
        }
        // npm requires / imports (non-relative)
        for pat in ["require('", "require(\"", "from '", "from \""] {
            for (i, _) in l.match_indices(pat) {
                let rest = &l[i + pat.len()..];
                if let Some(end) = rest.find(['\'', '"']) {
                    let dep = &rest[..end];
                    if !dep.starts_with('.') && !dep.starts_with('/') && seen.insert(format!("npm:{dep}")) {
                        findings.push(Finding {
                            name: dep.to_string(),
                            kind: "npm",
                            class: Class::Convertible,
                            note: "npm lane — resolve + bundle at toolkit build time",
                        });
                    }
                }
            }
        }
        if interp.starts_with("python") {
            if let Some(m) = l.strip_prefix("import ").or_else(|| l.strip_prefix("from ")) {
                let dep = m.split([' ', '.']).next().unwrap_or("");
                if !dep.is_empty() && seen.insert(format!("pip:{dep}")) {
                    findings.push(Finding {
                        name: dep.to_string(),
                        kind: "pip",
                        class: Class::Blocked,
                        note: "no python lane",
                    });
                }
            }
        }
    }

    // worst-of rolls up
    let class = findings
        .iter()
        .map(|f| f.class)
        .max_by_key(|c| match c {
            Class::Ready => 0,
            Class::Convertible => 1,
            Class::Blocked => 2,
        })
        .unwrap_or(Class::Ready);
    Ok(ScriptAudit { file: path.file_name().unwrap_or_default().to_string_lossy().into(), interpreter: interp, class, findings })
}

pub fn audit_dir(dir: &Path) -> Result<Vec<ScriptAudit>> {
    let sdir = dir.join("scripts");
    let mut out = vec![];
    if sdir.is_dir() {
        let mut files: Vec<_> = std::fs::read_dir(&sdir)?
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.is_file())
            .collect();
        files.sort();
        for f in files {
            out.push(audit_script(&f)?);
        }
    }
    Ok(out)
}

/// Rewrite the manifest's audit section in place — the artifact carries its
/// own findings. Replaces the stage-1 TODO or a previous audit run.
pub fn write_into_manifest(dir: &Path, audits: &[ScriptAudit]) -> Result<()> {
    let mpath = dir.join("manifest.org");
    let m = std::fs::read_to_string(&mpath).with_context(|| format!("read {}", mpath.display()))?;
    let cut = m
        .find("** TODO dependency audit")
        .or_else(|| m.find("** dependency audit"))
        .unwrap_or(m.len());
    let mut section = String::from("** dependency audit (static, auto)\n");
    if audits.is_empty() {
        section.push_str("   no carried scripts — guidance-only toolkit, nothing to convert.\n");
    }
    for a in audits {
        section.push_str(&format!("*** {} — {} ({})\n", a.file, a.class.s(), a.interpreter));
        for f in &a.findings {
            section.push_str(&format!("    - {} ={}= :: {} — {}\n", f.kind, f.name, f.class.s(), f.note));
        }
    }
    let id = m
        .lines()
        .find_map(|l| l.strip_prefix("#+TOOLKIT:"))
        .map(|v| v.trim().to_string())
        .unwrap_or_else(|| "<id>".into());
    section.push('\n');
    section.push_str(&fixup_plan(&id, audits));
    std::fs::write(&mpath, format!("{}{}", &m[..cut], section))?;
    Ok(())
}

// ── stage 3: the fix-up plan (the agent manual) ─────────────────────────────

/// Concrete steps per finding — which lane, which recipe, what to rewrite.
fn recipe(f: &Finding) -> Vec<String> {
    match (f.kind, f.name.as_str()) {
        ("interpreter", "python" | "python3" | "ruby" | "perl") => vec![
            format!("rewrite in JS for the quickjs lane — keep the script's CLI contract (same args in, same stdout out) so callers don't change"),
            format!("or split the logic into org tasks the engine runs natively"),
        ],
        ("interpreter", "sh" | "bash" | "zsh" | "node" | "js") => vec![],
        ("interpreter", _) => vec![
            format!("identify the language; if it's in a compile lane (c/zig/rust/go) declare a build recipe in the manifest, then =wbx toolkit build= produces the wasm"),
        ],
        ("binary", "curl" | "wget") => vec![
            format!("route HTTP through the Dock instead of a raw binary — in JS use =fetch= (engine-shimmed); in shell, call the engine's http capability from a task"),
        ],
        ("binary", "git") => vec![
            format!("call engine-side git (a brokered capability) from the task instead of the local binary"),
        ],
        ("binary", "npm" | "npx" | "bun" | "node") => vec![
            format!("drop install-at-runtime — declare the deps and let =wbx toolkit build= resolve + bundle them via the npm lane at build time"),
        ],
        ("binary", _) => vec![
            format!("no sandbox equivalent — move this behavior onto an engine capability, or redesign the step out"),
        ],
        ("npm", _) => vec![
            format!("declare ={}= as a dependency in the manifest; =wbx toolkit build= bundles it via the npm lane", f.name),
        ],
        ("pip", _) => vec![
            format!("={}= goes away with the python rewrite (see the interpreter item)", f.name),
        ],
        _ => vec![],
    }
}

/// The plan section: one TODO per non-ready script, concrete steps, and the
/// done-test spelled out. Empty plans say so honestly.
fn fixup_plan(id: &str, audits: &[ScriptAudit]) -> String {
    let work: Vec<&ScriptAudit> = audits.iter().filter(|a| a.class != Class::Ready).collect();
    if work.is_empty() {
        return format!(
            "** fix-up plan\n   nothing to fix — every script is sandbox-ready.\n                prove it: =wbx toolkit push {id} <dir>= then =wbx toolkit verify {id}=\n"
        );
    }
    let mut out = format!("** TODO fix-up plan [0/{}]\n", work.len());
    out.push_str(&format!(
        "   The agent manual: work each item, check it off, then prove the whole\n   \
         toolkit — done when =wbx toolkit push {id} <dir>= · =wbx toolkit build {id}=\n   \
         · =wbx toolkit verify {id}= all pass. With an engine reachable,\n   \
         =wbx toolkit audit <dir> --fix= runs that push→build→verify for you.\n"
    ));
    for a in &work {
        out.push_str(&format!("*** TODO {} ({} — {})\n", a.file, a.class.s(), a.interpreter));
        for f in &a.findings {
            for step in recipe(f) {
                out.push_str(&format!("    - [ ] {step}\n"));
            }
        }
        out.push_str(&format!("    - [ ] re-run =wbx toolkit audit= — {} must classify ready\n", a.file));
    }
    out
}

/// `wbx toolkit audit <dir> [--fix]` — static report per mode (exit 0: a
/// diagnosis isn't a failure); `--fix` is the auto-convert: push the toolkit
/// to the engine, run its builds, verify — the engine errors map to the
/// standard exit codes if it's unreachable.
pub fn audit(dir: &str, human: bool, fix: bool, io: &dyn crate::io::Io) -> Result<String> {
    let report = audit_static(dir, human)?;
    if !fix {
        return Ok(report);
    }
    let mpath = Path::new(dir).join("manifest.org");
    let m = std::fs::read_to_string(&mpath)?;
    let id = m
        .lines()
        .find_map(|l| l.strip_prefix("#+TOOLKIT:"))
        .map(|v| v.trim().to_string())
        .context("manifest.org has no #+TOOLKIT: id")?;
    let pushed = crate::commands::toolkit_push(io, &id, dir)?;
    let built = crate::commands::toolkit_build(io, &id, None)?;
    let verified = crate::commands::toolkit_verify(io, &id)?;
    if human {
        Ok(format!("{report}\n\nfix: pushed {id} → built → verified\n{verified}"))
    } else {
        Ok(serde_json::json!({
            "audit": serde_json::from_str::<serde_json::Value>(&report).unwrap_or(serde_json::json!({"text": report})),
            "fix": { "pushed": pushed, "built": built, "verified": verified },
        })
        .to_string())
    }
}

/// The static stages (2+3): scan, classify, write findings + plan into the manifest.
pub fn audit_static(dir: &str, human: bool) -> Result<String> {
    let d = Path::new(dir);
    let audits = audit_dir(d)?;
    write_into_manifest(d, &audits)?;
    let (r, c, b) = audits.iter().fold((0, 0, 0), |(r, c, b), a| match a.class {
        Class::Ready => (r + 1, c, b),
        Class::Convertible => (r, c + 1, b),
        Class::Blocked => (r, c, b + 1),
    });
    if human {
        let mut out = format!(
            "audited {} script{} — {r} ready · {c} convertible · {b} blocked\n",
            audits.len(),
            if audits.len() == 1 { "" } else { "s" }
        );
        for a in &audits {
            out.push_str(&format!("  {:<24} {:<12} ({})\n", a.file, a.class.s(), a.interpreter));
        }
        out.push_str("findings written into manifest.org");
        Ok(out)
    } else {
        Ok(serde_json::json!({
            "scripts": audits.iter().map(|a| serde_json::json!({
                "file": a.file,
                "interpreter": a.interpreter,
                "class": a.class.s(),
                "findings": a.findings.iter().map(|f| serde_json::json!({
                    "name": f.name, "kind": f.kind, "class": f.class.s(), "note": f.note,
                })).collect::<Vec<_>>(),
            })).collect::<Vec<_>>(),
            "summary": { "ready": r, "convertible": c, "blocked": b },
        })
        .to_string())
    }
}
