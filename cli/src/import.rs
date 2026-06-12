//! `wbx toolkit import` — stage 1 of the intake ramp (cli/SPEC.md § Import):
//! detect a source's shape, translate its docs to org, and scaffold a real
//! toolkit (manifest.org + skills/ + carried scripts) that `wbx toolkit push`
//! will accept. Parse-only and local-only here; the dependency audit and
//! fix-up plans are stage 2/3. Guidance-only toolkits are a valid landing.

use anyhow::{bail, Context, Result};
use std::path::{Path, PathBuf};

#[derive(Debug, PartialEq, Clone, Copy)]
pub enum Kind {
    ClaudeSkill,
    Markdown,
    Folder,
}

impl Kind {
    fn parse(s: &str) -> Result<Kind> {
        Ok(match s {
            "claude-skill" => Kind::ClaudeSkill,
            "markdown" => Kind::Markdown,
            "folder" => Kind::Folder,
            other => bail!(
                "unknown --as kind '{other}' (have: claude-skill, markdown, folder; \
                 mcp-server/openapi/npm-cli land with the source-taxonomy issue)"
            ),
        })
    }
    fn name(&self) -> &'static str {
        match self {
            Kind::ClaudeSkill => "claude-skill",
            Kind::Markdown => "markdown",
            Kind::Folder => "folder",
        }
    }
}

/// Detect by shape; `--as` overrides.
fn detect(src: &Path, forced: Option<&str>) -> Result<Kind> {
    if let Some(k) = forced {
        return Kind::parse(k);
    }
    if src.is_file() {
        let name = src.file_name().unwrap_or_default().to_string_lossy();
        if name.eq_ignore_ascii_case("SKILL.md") {
            return Ok(Kind::ClaudeSkill);
        }
        if name.to_lowercase().ends_with(".md") {
            return Ok(Kind::Markdown);
        }
        bail!("can't detect a kind for {name} — pass --as <kind>");
    }
    if src.is_dir() {
        if src.join("SKILL.md").is_file() {
            return Ok(Kind::ClaudeSkill);
        }
        return Ok(Kind::Folder);
    }
    // not a local path: likely a skills.sh / owner-repo reference
    let s = src.to_string_lossy();
    if !s.contains('/') || s.starts_with("http") || s.matches('/').count() == 1 {
        bail!(
            "{s} is not a local path. Remote refs (skills.sh, owner/repo) aren't \
             wired yet — clone it locally and import the folder:\n  git clone … && wbx toolkit import <dir>"
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

struct Imported {
    id: String,
    tagline: String,
    skills: Vec<(String, String)>, // (name, org body)
    scripts: Vec<PathBuf>,         // carried verbatim, audited in stage 2
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
    if !t.scripts.is_empty() {
        let sdir = out_dir.join("scripts");
        std::fs::create_dir_all(&sdir)?;
        manifest.push_str("\n** carried scripts (unaudited)\n");
        for s in &t.scripts {
            let name = s.file_name().unwrap_or_default().to_string_lossy().to_string();
            std::fs::copy(s, sdir.join(&name)).with_context(|| format!("copy {}", s.display()))?;
            manifest.push_str(&format!("   - =scripts/{name}=\n"));
        }
    }
    manifest.push_str(
        "\n** TODO dependency audit\n   The import was parse-only. Next: the wasm \
         compatibility audit classifies every\n   carried script ready/convertible/blocked \
         and writes the fix-up plan here.\n",
    );
    std::fs::write(out_dir.join("manifest.org"), &manifest)?;

    Ok(format!(
        "imported {} → {}/\n  manifest.org      the toolkit surface\n  skills/           {} skill{}\n{}\nnext: review manifest.org, then `wbx toolkit verify {}`",
        kind.name(),
        out_dir.display(),
        t.skills.len(),
        if t.skills.len() == 1 { "" } else { "s" },
        if t.scripts.is_empty() {
            String::new()
        } else {
            format!("  scripts/          {} carried (unaudited — see the TODO)\n", t.scripts.len())
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
    Ok(Imported { id, tagline, skills, scripts })
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
        scripts: vec![],
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
    Ok(Imported { id: id.clone(), tagline: format!("imported from folder {id}"), skills, scripts })
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

// ── entry ───────────────────────────────────────────────────────────────────

pub fn import(source: &str, as_kind: Option<&str>, out: Option<&str>) -> Result<String> {
    let src = Path::new(source);
    let kind = detect(src, as_kind)?;
    let t = match kind {
        Kind::ClaudeSkill => import_claude_skill(src)?,
        Kind::Markdown => import_markdown(src)?,
        Kind::Folder => import_folder(src)?,
    };
    let out_dir = out
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(format!("{}-toolkit", t.id)));
    write_scaffold(&out_dir, kind, src, &t)
}
