//! `work kit import` — stage 1 of the intake ramp (cli/SPEC.md § Import):
//! detect a source's shape, translate its docs to org, and scaffold a real
//! toolkit (manifest.org + skills/ + carried scripts) that `work kit push`
//! will accept. Parse-only and local-only here; the dependency audit and
//! fix-up plans are stage 2/3. Guidance-only toolkits are a valid landing.

use anyhow::{bail, Context, Result};
use std::path::{Path, PathBuf};

#[derive(Debug, PartialEq, Clone, Copy)]
pub enum Kind {
    ClaudeSkill,
    Markdown,
    Folder,
    McpServer,
    OpenApi,
    NpmCli,
    PipCli,
    CursorRules,
    AgentsMd,
}

impl Kind {
    fn parse(s: &str) -> Result<Kind> {
        Ok(match s {
            "claude-skill" => Kind::ClaudeSkill,
            "markdown" => Kind::Markdown,
            "folder" => Kind::Folder,
            "mcp-server" => Kind::McpServer,
            "openapi" => Kind::OpenApi,
            "npm-cli" => Kind::NpmCli,
            "pip-cli" => Kind::PipCli,
            "cursor-rules" => Kind::CursorRules,
            "agents-md" => Kind::AgentsMd,
            other => bail!(
                "unknown --as kind '{other}' (have: claude-skill, markdown, folder, \
                 mcp-server, openapi, npm-cli, pip-cli, cursor-rules, agents-md)"
            ),
        })
    }
    fn name(&self) -> &'static str {
        match self {
            Kind::ClaudeSkill => "claude-skill",
            Kind::Markdown => "markdown",
            Kind::Folder => "folder",
            Kind::McpServer => "mcp-server",
            Kind::OpenApi => "openapi",
            Kind::NpmCli => "npm-cli",
            Kind::PipCli => "pip-cli",
            Kind::CursorRules => "cursor-rules",
            Kind::AgentsMd => "agents-md",
        }
    }
}

/// Detect by shape; `--as` overrides.
fn detect(src: &Path, forced: Option<&str>) -> Result<Kind> {
    if let Some(k) = forced {
        return Kind::parse(k);
    }
    if src.is_file() {
        let name = src.file_name().unwrap_or_default().to_string_lossy().to_string();
        let lower = name.to_lowercase();
        if name.eq_ignore_ascii_case("SKILL.md") {
            return Ok(Kind::ClaudeSkill);
        }
        // identity files before the generic .md catch-all
        if name == "AGENTS.md" || name == "CLAUDE.md" {
            return Ok(Kind::AgentsMd);
        }
        if name == ".cursorrules" {
            return Ok(Kind::CursorRules);
        }
        if lower == ".mcp.json" || lower == "mcp.json" {
            return Ok(Kind::McpServer);
        }
        if lower == "package.json" {
            let body = std::fs::read_to_string(src).unwrap_or_default();
            if body.contains("\"bin\"") {
                return Ok(Kind::NpmCli);
            }
        }
        if lower == "pyproject.toml" {
            return Ok(Kind::PipCli);
        }
        // sniff specs by content, not just extension
        if lower.ends_with(".json") || lower.ends_with(".yaml") || lower.ends_with(".yml") {
            let head: String = std::fs::read_to_string(src).unwrap_or_default().chars().take(4096).collect();
            if head.contains("\"openapi\"") || head.contains("\"swagger\"") || head.lines().any(|l| l.starts_with("openapi:") || l.starts_with("swagger:")) {
                return Ok(Kind::OpenApi);
            }
        }
        if lower.ends_with(".md") {
            return Ok(Kind::Markdown);
        }
        bail!("can't detect a kind for {name} — pass --as <kind>");
    }
    if src.is_dir() {
        if src.join("SKILL.md").is_file() {
            return Ok(Kind::ClaudeSkill);
        }
        if src.join(".mcp.json").is_file() || src.join("mcp.json").is_file() {
            return Ok(Kind::McpServer);
        }
        if src.join("package.json").is_file()
            && std::fs::read_to_string(src.join("package.json")).unwrap_or_default().contains("\"bin\"")
        {
            return Ok(Kind::NpmCli);
        }
        if src.join("pyproject.toml").is_file() {
            return Ok(Kind::PipCli);
        }
        if src.join(".cursorrules").is_file() || src.join(".cursor/rules").is_dir() {
            return Ok(Kind::CursorRules);
        }
        return Ok(Kind::Folder);
    }
    // not a local path: likely a skills.sh / owner-repo reference
    let s = src.to_string_lossy();
    if !s.contains('/') || s.starts_with("http") || s.matches('/').count() == 1 {
        bail!(
            "{s} is not a local path. Remote refs (skills.sh, owner/repo) aren't \
             wired yet — clone it locally and import the folder:\n  git clone … && work kit import <dir>"
        );
    }
    bail!("not found: {s}")
}

// ── md → org, the mechanical 90% ────────────────────────────────────────────

/// YAML frontmatter (--- … ---) → (keywords, rest-of-body).
fn split_frontmatter(md: &str) -> (Vec<(String, String)>, String) {
    let mut lines = md.lines();
    if lines.next().map(|l| l.trim()) != Some("---") {
        return (vec![], md.to_string());
    }
    let mut kv = vec![];
    let mut consumed = 1;
    let mut in_block = false; // skip folded/multiline values (key: > / key: |)
    for line in lines {
        consumed += 1;
        let t = line.trim_end();
        if t.trim() == "---" {
            let body: String = md.lines().skip(consumed).collect::<Vec<_>>().join("\n");
            return (kv, body);
        }
        if in_block {
            if !t.starts_with(' ') {
                in_block = false;
            } else {
                if let Some((k, v)) = kv.last_mut().map(|(k, v)| (k.clone(), v)) {
                    let _ = k;
                    v.push(' ');
                    v.push_str(t.trim());
                }
                continue;
            }
        }
        if let Some((k, v)) = t.split_once(':') {
            let v = v.trim();
            in_block = v == ">" || v == "|" || v.is_empty();
            kv.push((k.trim().to_string(), if in_block { String::new() } else { v.trim_matches('"').to_string() }));
        }
    }
    (vec![], md.to_string()) // unterminated frontmatter — treat as body
}

/// Mechanical markdown → org. Honest 90%: headings, fences, links, inline
/// code, bold. What it can't translate it passes through — org tolerates it.
pub fn md_to_org(md: &str) -> String {
    let mut out = String::new();
    let mut in_fence = false;
    for line in md.lines() {
        let t = line.trim_start();
        if let Some(rest) = t.strip_prefix("```") {
            if in_fence {
                out.push_str("#+end_src\n");
            } else {
                let lang = rest.trim();
                out.push_str(&format!(
                    "#+begin_src {}\n",
                    if lang.is_empty() { "text" } else { lang }
                ));
            }
            in_fence = !in_fence;
            continue;
        }
        if in_fence {
            out.push_str(line);
            out.push('\n');
            continue;
        }
        // headings: #… → *…
        if let Some(n) = t.bytes().take_while(|b| *b == b'#').count().checked_sub(0) {
            if n > 0 && t.as_bytes().get(n).copied() == Some(b' ') {
                out.push_str(&"*".repeat(n));
                out.push_str(&t[n..]);
                out.push('\n');
                continue;
            }
        }
        // inline: links, code, bold
        let mut l = line.to_string();
        // [text](url) → [[url][text]]
        while let (Some(a), Some(b)) = (l.find("]("), l.find('[')) {
            if b > a {
                break;
            }
            let Some(c) = l[a..].find(')') else { break };
            let text = l[b + 1..a].to_string();
            let url = l[a + 2..a + c].to_string();
            l.replace_range(b..a + c + 1, &format!("[[{url}][{text}]]"));
        }
        let l = l.replace("**", "*"); // md bold → org bold
        let l = l
            .split('`')
            .enumerate()
            .map(|(i, part)| if i % 2 == 1 { format!("={part}=") } else { part.to_string() })
            .collect::<String>();
        out.push_str(&l);
        out.push('\n');
    }
    if in_fence {
        out.push_str("#+end_src\n");
    }
    out
}

fn slug(s: &str) -> String {
    s.to_lowercase()
        .chars()
        .map(|c| if c.is_alphanumeric() { c } else { '-' })
        .collect::<String>()
        .split('-')
        .filter(|p| !p.is_empty())
        .collect::<Vec<_>>()
        .join("-")
}

// ── the scaffold ────────────────────────────────────────────────────────────

#[derive(Default)]
struct Imported {
    id: String,
    tagline: String,
    skills: Vec<(String, String)>,      // (name, org body)
    scripts: Vec<PathBuf>,              // carried verbatim, audited in stage 2
    synth_scripts: Vec<(String, String)>, // (filename, content) — written so the audit sees them
}

fn write_scaffold(out_dir: &Path, kind: Kind, src: &Path, t: &Imported) -> Result<String> {
    if out_dir.exists() {
        bail!("{} already exists", out_dir.display());
    }
    let skills_dir = out_dir.join("skills");
    std::fs::create_dir_all(&skills_dir)?;

    let mut manifest = format!(
        "#+TITLE: {id} toolkit\n#+TOOLKIT: {id}\n#+VERSION: 0.1.0\n#+KIND: toolkit\n\
         #+STATUS: imported\n#+TAGLINE: {tagline}\n#+IMPORTED_FROM: {kind} {src}\n\n\
         * {id} — imported toolkit                                   :toolkit:\n\
         \x20 :PROPERTIES:\n  :ID:        {id}\n  :KIND:      toolkit\n  :STATUS:    imported\n\
         \x20 :SKILL_DIR: skills/\n  :END:\n\n\
         \x20 Imported from a {kind} source. The skill tree below is the readable\n\
         \x20 surface; anything under =scripts/= is carried verbatim and NOT yet\n\
         \x20 trusted to run in the sandbox.\n\n** skills\n",
        id = t.id,
        tagline = t.tagline,
        kind = kind.name(),
        src = src.display(),
    );
    for (name, body) in &t.skills {
        let file = format!("{}.org", slug(name));
        std::fs::write(skills_dir.join(&file), body)?;
        manifest.push_str(&format!("   - [[file:skills/{file}][{name}]]\n"));
    }
    if !t.scripts.is_empty() || !t.synth_scripts.is_empty() {
        let sdir = out_dir.join("scripts");
        std::fs::create_dir_all(&sdir)?;
        manifest.push_str("\n** carried scripts (unaudited)\n");
        for s in &t.scripts {
            let name = s.file_name().unwrap_or_default().to_string_lossy().to_string();
            std::fs::copy(s, sdir.join(&name)).with_context(|| format!("copy {}", s.display()))?;
            manifest.push_str(&format!("   - =scripts/{name}=\n"));
        }
        for (name, content) in &t.synth_scripts {
            std::fs::write(sdir.join(name), content)?;
            manifest.push_str(&format!("   - =scripts/{name}= (synthesized from the source's entry point)\n"));
        }
    }
    manifest.push_str(
        "\n** TODO dependency audit\n   The import was parse-only. Next: the wasm \
         compatibility audit classifies every\n   carried script ready/convertible/blocked \
         and writes the fix-up plan here.\n",
    );
    std::fs::write(out_dir.join("manifest.org"), &manifest)?;

    Ok(format!(
        "imported {} → {}/\n  manifest.org      the toolkit surface\n  skills/           {} skill{}\n{}\nnext: review manifest.org, then `work kit verify {}`",
        kind.name(),
        out_dir.display(),
        t.skills.len(),
        if t.skills.len() == 1 { "" } else { "s" },
        if t.scripts.is_empty() && t.synth_scripts.is_empty() {
            String::new()
        } else {
            format!(
                "  scripts/          {} carried (unaudited — see the TODO)\n",
                t.scripts.len() + t.synth_scripts.len()
            )
        },
        t.id,
    ))
}

// ── per-kind parsers ────────────────────────────────────────────────────────

fn import_claude_skill(src: &Path) -> Result<Imported> {
    let (dir, skill_md) = if src.is_file() {
        (src.parent().unwrap_or(Path::new(".")).to_path_buf(), src.to_path_buf())
    } else {
        (src.to_path_buf(), src.join("SKILL.md"))
    };
    let md = std::fs::read_to_string(&skill_md).with_context(|| format!("read {}", skill_md.display()))?;
    let (fm, body) = split_frontmatter(&md);
    let get = |k: &str| fm.iter().find(|(key, _)| key == k).map(|(_, v)| v.clone());
    let id = get("name").map(|n| slug(&n)).unwrap_or_else(|| {
        slug(&dir.file_name().unwrap_or_default().to_string_lossy())
    });
    let tagline = get("description")
        .unwrap_or_else(|| "imported Claude skill".into())
        .replace('\n', " ")
        .chars()
        .take(220)
        .collect();

    let mut skills = vec![(id.clone(), md_to_org(&body))];
    // references/*.md ride along as further skills
    let refs = dir.join("references");
    if refs.is_dir() {
        let mut entries: Vec<_> = std::fs::read_dir(&refs)?
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.extension().map(|e| e == "md").unwrap_or(false))
            .collect();
        entries.sort();
        for p in entries {
            let name = p.file_stem().unwrap_or_default().to_string_lossy().to_string();
            let body = std::fs::read_to_string(&p)?;
            skills.push((format!("reference-{name}"), md_to_org(&body)));
        }
    }
    // scripts carried verbatim
    let scripts = collect_scripts(&dir)?;
    Ok(Imported { id, tagline, skills, scripts, ..Default::default() })
}

fn import_markdown(src: &Path) -> Result<Imported> {
    let md = std::fs::read_to_string(src).with_context(|| format!("read {}", src.display()))?;
    let (fm, body) = split_frontmatter(&md);
    let get = |k: &str| fm.iter().find(|(key, _)| key == k).map(|(_, v)| v.clone());
    let id = get("name")
        .map(|n| slug(&n))
        .unwrap_or_else(|| slug(&src.file_stem().unwrap_or_default().to_string_lossy()));
    let tagline = get("description")
        .or_else(|| body.lines().find(|l| !l.trim().is_empty() && !l.starts_with('#')).map(String::from))
        .unwrap_or_else(|| "imported document".into());
    Ok(Imported {
        id: id.clone(),
        tagline,
        skills: vec![(id, md_to_org(&body))],
        ..Default::default()
    })
}

fn import_folder(src: &Path) -> Result<Imported> {
    let id = slug(&src.file_name().unwrap_or_default().to_string_lossy());
    let mut skills = vec![];
    let mut entries: Vec<_> = std::fs::read_dir(src)?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().map(|e| e == "md").unwrap_or(false))
        .collect();
    entries.sort();
    for p in &entries {
        let name = p.file_stem().unwrap_or_default().to_string_lossy().to_string();
        skills.push((name, md_to_org(&std::fs::read_to_string(p)?)));
    }
    if skills.is_empty() {
        skills.push((
            id.clone(),
            format!("* {id}\n\n  Imported folder — no docs found; describe the toolkit here.\n"),
        ));
    }
    let scripts = collect_scripts(src)?;
    Ok(Imported { id: id.clone(), tagline: format!("imported from folder {id}"), skills, scripts, ..Default::default() })
}

fn collect_scripts(dir: &Path) -> Result<Vec<PathBuf>> {
    let mut out = vec![];
    for sub in ["scripts", "bin"] {
        let d = dir.join(sub);
        if d.is_dir() {
            for e in std::fs::read_dir(&d)? {
                let p = e?.path();
                if p.is_file() {
                    out.push(p);
                }
            }
        }
    }
    out.sort();
    Ok(out)
}


/// .mcp.json — skill per server entry; each server's launch command becomes a
/// synthesized script so the audit judges it (the server IS the bin).
/// Tools are runtime-enumerated; that honesty goes in the skill text.
fn import_mcp_server(src: &Path) -> Result<Imported> {
    let cfg_path = if src.is_dir() {
        ["mcp.json", ".mcp.json"].iter().map(|n| src.join(n)).find(|p| p.is_file())
            .context("no mcp.json/.mcp.json in the directory")?
    } else {
        src.to_path_buf()
    };
    let v: serde_json::Value = serde_json::from_str(
        &std::fs::read_to_string(&cfg_path).with_context(|| format!("read {}", cfg_path.display()))?,
    ).context("mcp config is not valid JSON")?;
    let servers = v.get("mcpServers").and_then(|s| s.as_object())
        .or_else(|| v.as_object().filter(|o| o.values().any(|e| e.get("command").is_some())))
        .context("no mcpServers map found (expected {\"mcpServers\": {name: {command, args}}})")?;

    let stem = src.file_stem().unwrap_or_default().to_string_lossy().to_string();
    let id = if servers.len() == 1 {
        slug(servers.keys().next().unwrap())
    } else {
        slug(if src.is_dir() { &stem } else { "mcp-servers" })
    };
    let mut skills = vec![];
    let mut synth_scripts = vec![];
    for (name, entry) in servers {
        let command = entry.get("command").and_then(|c| c.as_str()).unwrap_or("");
        let args: Vec<String> = entry.get("args").and_then(|a| a.as_array())
            .map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect())
            .unwrap_or_default();
        let env_keys: Vec<&str> = entry.get("env").and_then(|e| e.as_object())
            .map(|o| o.keys().map(|k| k.as_str()).collect())
            .unwrap_or_default();
        let mut body = format!(
            "* {name} (MCP server)\n\n  Launch: ={command} {}=\n", args.join(" ")
        );
        if !env_keys.is_empty() {
            // names only — config values may be secrets, they never leave the source
            body.push_str(&format!("  Env (names only; set values engine-side): {}\n", env_keys.join(", ")));
        }
        body.push_str(
            "\n  MCP tools are enumerated at runtime, not in the config — run the\n  \
             server to list them, then document each as its own skill.\n",
        );
        skills.push((slug(name), body));
        synth_scripts.push((
            format!("{}.sh", slug(name)),
            format!("#!/bin/sh\n# the MCP server launch — the server is the toolkit bin\nexec {command} {}\n", args.join(" ")),
        ));
    }
    Ok(Imported {
        id,
        tagline: format!("imported MCP config — {} server{}", servers.len(), if servers.len() == 1 { "" } else { "s" }),
        skills,
        synth_scripts,
        ..Default::default()
    })
}

/// OpenAPI (JSON) — skill per operation; HTTP goes through the engine.
/// YAML specs get the convert-it hint rather than a half-parse.
fn import_openapi(src: &Path) -> Result<Imported> {
    let raw = std::fs::read_to_string(src).with_context(|| format!("read {}", src.display()))?;
    let v: serde_json::Value = serde_json::from_str(&raw).map_err(|_| {
        anyhow::anyhow!(
            "only JSON OpenAPI specs parse today — convert YAML first:\n  yq -o=json spec.yaml > spec.json && work kit import spec.json"
        )
    })?;
    let info = &v["info"];
    let id = slug(info["title"].as_str().unwrap_or("api"));
    let tagline = info["description"].as_str()
        .map(|d| d.replace('\n', " ").chars().take(220).collect())
        .unwrap_or_else(|| format!("imported OpenAPI surface: {id}"));
    let mut skills = vec![];
    if let Some(paths) = v["paths"].as_object() {
        for (path, ops) in paths {
            let Some(ops) = ops.as_object() else { continue };
            for (method, op) in ops {
                if !["get", "post", "put", "patch", "delete", "head", "options"].contains(&method.as_str()) {
                    continue;
                }
                let name = op["operationId"].as_str()
                    .map(slug)
                    .unwrap_or_else(|| slug(&format!("{method}-{path}")));
                let summary = op["summary"].as_str().or(op["description"].as_str()).unwrap_or("");
                let mut body = format!(
                    "* {name}\n\n  ={}= ={path}=\n\n  {summary}\n", method.to_uppercase()
                );
                if let Some(params) = op["parameters"].as_array() {
                    if !params.is_empty() {
                        body.push_str("\n  Parameters:\n");
                        for p in params {
                            body.push_str(&format!(
                                "  - ={}= ({}{})\n",
                                p["name"].as_str().unwrap_or("?"),
                                p["in"].as_str().unwrap_or("?"),
                                if p["required"].as_bool().unwrap_or(false) { ", required" } else { "" },
                            ));
                        }
                    }
                }
                body.push_str("\n  HTTP runs through the engine (Dock-brokered) — no raw sockets.\n");
                skills.push((name, body));
            }
        }
    }
    if skills.is_empty() {
        bail!("the spec has no operations under paths — nothing to import");
    }
    Ok(Imported { id, tagline, skills, ..Default::default() })
}

/// package.json with bin — README becomes the manual, the bin files are
/// carried so the audit + fix-up plan judge the npm-lane build.
fn import_npm_cli(src: &Path) -> Result<Imported> {
    let dir = if src.is_dir() { src.to_path_buf() } else { src.parent().unwrap_or(Path::new(".")).to_path_buf() };
    let pkg: serde_json::Value = serde_json::from_str(
        &std::fs::read_to_string(dir.join("package.json")).context("read package.json")?,
    ).context("package.json is not valid JSON")?;
    let raw_name = pkg["name"].as_str().unwrap_or("npm-cli");
    let id = slug(raw_name.rsplit('/').next().unwrap_or(raw_name)); // strip @scope/
    let tagline = pkg["description"].as_str().unwrap_or("imported npm CLI").to_string();

    // bin: "path" or { name: "path" } — carry every target that exists
    let mut scripts = vec![];
    match &pkg["bin"] {
        serde_json::Value::String(p) => scripts.push(dir.join(p)),
        serde_json::Value::Object(m) => scripts.extend(m.values().filter_map(|p| p.as_str()).map(|p| dir.join(p))),
        _ => {}
    }
    scripts.retain(|p| p.is_file());

    let mut skills = vec![];
    for readme in ["README.md", "readme.md", "Readme.md"] {
        if let Ok(md) = std::fs::read_to_string(dir.join(readme)) {
            skills.push((id.clone(), md_to_org(&md)));
            break;
        }
    }
    if skills.is_empty() {
        skills.push((id.clone(), format!("* {id}\n\n  {tagline}\n\n  (no README found — document usage here)\n")));
    }
    Ok(Imported { id, tagline, skills, scripts, ..Default::default() })
}

/// pyproject.toml — each console script becomes a synthesized python stub so
/// the audit tells the truth (blocked: no python lane) and the fix-up plan
/// carries the rewrite instructions. Minimal line-parse; no toml dep.
fn import_pip_cli(src: &Path) -> Result<Imported> {
    let dir = if src.is_dir() { src.to_path_buf() } else { src.parent().unwrap_or(Path::new(".")).to_path_buf() };
    let toml = std::fs::read_to_string(dir.join("pyproject.toml")).context("read pyproject.toml")?;
    let field = |key: &str| {
        toml.lines()
            .map(str::trim)
            .find_map(|l| l.strip_prefix(key).and_then(|r| r.trim().strip_prefix('=')))
            .map(|v| v.trim().trim_matches(['"', '\'']).to_string())
    };
    let id = field("name").map(|n| slug(&n)).unwrap_or_else(|| slug(&dir.file_name().unwrap_or_default().to_string_lossy()));
    let tagline = field("description").unwrap_or_else(|| "imported python CLI".into());

    // [project.scripts] / [console_scripts] section: name = "module:func"
    let mut synth_scripts = vec![];
    let mut in_scripts = false;
    for line in toml.lines().map(str::trim) {
        if line.starts_with('[') {
            in_scripts = line.contains("scripts]");
            continue;
        }
        if in_scripts && line.contains('=') {
            if let Some((name, target)) = line.split_once('=') {
                synth_scripts.push((
                    format!("{}.py", slug(name.trim())),
                    format!(
                        "#!/usr/bin/env python3\n# entry point: {} — synthesized for the audit;\n# the real implementation lives in the package\n",
                        target.trim().trim_matches('"')
                    ),
                ));
            }
        }
    }
    let mut skills = vec![];
    for readme in ["README.md", "readme.md"] {
        if let Ok(md) = std::fs::read_to_string(dir.join(readme)) {
            skills.push((id.clone(), md_to_org(&md)));
            break;
        }
    }
    if skills.is_empty() {
        skills.push((id.clone(), format!("* {id}\n\n  {tagline}\n")));
    }
    Ok(Imported { id, tagline, skills, synth_scripts, ..Default::default() })
}

/// .cursorrules / .cursor/rules — guidance-only toolkit, one skill per rule file.
fn import_cursor_rules(src: &Path) -> Result<Imported> {
    let dir = if src.is_dir() { src.to_path_buf() } else { src.parent().unwrap_or(Path::new(".")).to_path_buf() };
    let id = slug(&format!("{}-rules", dir.file_name().unwrap_or_default().to_string_lossy()));
    let mut skills = vec![];
    let single = if src.is_file() { src.to_path_buf() } else { dir.join(".cursorrules") };
    if single.is_file() {
        skills.push(("rules".into(), md_to_org(&std::fs::read_to_string(&single)?)));
    }
    let rules_dir = dir.join(".cursor/rules");
    if rules_dir.is_dir() {
        let mut entries: Vec<_> = std::fs::read_dir(&rules_dir)?
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.is_file())
            .collect();
        entries.sort();
        for p in entries {
            let name = p.file_stem().unwrap_or_default().to_string_lossy().to_string();
            skills.push((slug(&name), md_to_org(&std::fs::read_to_string(&p)?)));
        }
    }
    if skills.is_empty() {
        bail!("no .cursorrules file or .cursor/rules directory found");
    }
    Ok(Imported { id, tagline: "imported cursor rules (guidance-only)".into(), skills, ..Default::default() })
}

/// AGENTS.md / CLAUDE.md — guidance-only toolkit.
fn import_agents_md(src: &Path) -> Result<Imported> {
    let md = std::fs::read_to_string(src).with_context(|| format!("read {}", src.display()))?;
    let parent = src.parent().and_then(|p| p.file_name()).unwrap_or_default().to_string_lossy().to_string();
    let id = slug(&format!("{parent}-agent-guide"));
    let tagline = md.lines()
        .find(|l| !l.trim().is_empty() && !l.starts_with('#'))
        .unwrap_or("imported agent instructions (guidance-only)")
        .chars().take(220).collect();
    Ok(Imported { id: id.clone(), tagline, skills: vec![(id, md_to_org(&md))], ..Default::default() })
}

// ── entry ───────────────────────────────────────────────────────────────────

pub fn import(source: &str, as_kind: Option<&str>, out: Option<&str>, human: bool) -> Result<String> {
    let src = Path::new(source);
    let kind = detect(src, as_kind)?;
    let t = match kind {
        Kind::ClaudeSkill => import_claude_skill(src)?,
        Kind::Markdown => import_markdown(src)?,
        Kind::Folder => import_folder(src)?,
        Kind::McpServer => import_mcp_server(src)?,
        Kind::OpenApi => import_openapi(src)?,
        Kind::NpmCli => import_npm_cli(src)?,
        Kind::PipCli => import_pip_cli(src)?,
        Kind::CursorRules => import_cursor_rules(src)?,
        Kind::AgentsMd => import_agents_md(src)?,
    };
    let out_dir = out
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(format!("{}-toolkit", t.id)));
    let msg = write_scaffold(&out_dir, kind, src, &t)?;
    // stage 2 runs automatically — the tool does the work, the artifact
    // carries its own audit; agents re-run with `work kit audit`
    let audit_line = match crate::audit::audit_static(&out_dir.to_string_lossy(), human) {
        Ok(report) if human => format!("\n\n{report}"),
        Ok(_) => String::new(),
        Err(e) => format!("\n\naudit skipped: {e:#}"),
    };
    Ok(format!("{msg}{audit_line}"))
}
