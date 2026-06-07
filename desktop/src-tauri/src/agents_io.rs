// Agent file I/O — user-scope CRUD against the agent catalog at
// `~/Workbooks/Engine/agents/<slug>.org`.
//
// The desktop chat picker + Settings → Agents panel consult the
// engine's `GET /api/agents` for the parsed catalog, but creating /
// updating / deleting a user-scope agent doesn't need the engine up
// (and shouldn't — the user is configuring, not running). These
// commands write the .org bytes directly so authoring works offline
// and pre-engine-ready.
//
// Why not `editor_io::file_save`: that's gated against the active
// workspace scope (D3), and this dir is user-scope config, not
// workspace content. Sharing the scope guard between user-config and
// workspace-content would conflate two concerns. This module owns the
// user-scope write surface for agents.
//
// Slugs are validated against the same regex as the entity binding
// (`^[a-z][a-z0-9-]*$`) so the filename matches `:ID:` in the .org
// drawer when the file is loaded.

#![allow(clippy::module_name_repetitions)]

use std::collections::BTreeMap;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use tokio::fs;
use oql_core::Document;

const MAX_AGENT_BYTES: usize = 64 * 1024;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AgentFile {
    pub slug: String,
    pub path: String,
    pub source: String,
}

/// `~/Workbooks/Engine/agents/` — the user-scope agent dir
/// `Workbooks.Engine.AgentCatalog` walks. Lives under the data root so the
/// IPC `ensure_in_data_root` guard can serve "view source" reads from
/// the renderer.
fn user_agents_dir() -> Result<PathBuf, String> {
    Ok(crate::config_paths::workhorse_root().join("agents"))
}

#[allow(dead_code)]
fn dirs_home() -> PathBuf {
    #[cfg(unix)]
    {
        std::env::var("HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|_| PathBuf::from("/tmp"))
    }
    #[cfg(windows)]
    {
        std::env::var("USERPROFILE")
            .map(PathBuf::from)
            .unwrap_or_else(|_| PathBuf::from("C:\\"))
    }
}

fn validate_slug(slug: &str) -> Result<(), String> {
    if slug.is_empty() {
        return Err("slug cannot be empty".into());
    }
    if slug.len() > 64 {
        return Err("slug too long (max 64 chars)".into());
    }
    let first = slug.chars().next().unwrap();
    if !first.is_ascii_lowercase() {
        return Err("slug must start with a lowercase letter".into());
    }
    for c in slug.chars() {
        if !(c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-') {
            return Err(format!(
                "slug contains invalid character '{c}' — use [a-z0-9-]"
            ));
        }
    }
    Ok(())
}

fn validate_source(source: &str) -> Result<(), String> {
    if source.is_empty() {
        return Err("source cannot be empty".into());
    }
    if source.len() > MAX_AGENT_BYTES {
        return Err(format!(
            "source too large ({} bytes; max {})",
            source.len(),
            MAX_AGENT_BYTES
        ));
    }
    // Cheap sniff for the canonical shape — the parser will catch the
    // rest server-side. We want loud failure for obvious mistakes
    // (someone pastes random text) before the file lands on disk.
    if !source.contains(":agent:") {
        return Err("source missing :agent: tag on the top-level headline".into());
    }
    if !source.contains(":ID:") {
        return Err("source missing :ID: property in the drawer".into());
    }
    Ok(())
}

async fn write_agent(slug: &str, source: &str) -> Result<AgentFile, String> {
    validate_slug(slug)?;
    validate_source(source)?;
    let dir = user_agents_dir()?;
    fs::create_dir_all(&dir)
        .await
        .map_err(|e| format!("mkdir {}: {e}", dir.display()))?;
    let path = dir.join(format!("{slug}.org"));
    fs::write(&path, source.as_bytes())
        .await
        .map_err(|e| format!("write {}: {e}", path.display()))?;
    Ok(AgentFile {
        slug: slug.to_string(),
        path: path.to_string_lossy().into_owned(),
        source: source.to_string(),
    })
}

#[derive(Deserialize)]
pub struct AgentCreateReq {
    pub slug: String,
    pub source: String,
}

#[tauri::command]
pub async fn agents_create(req: AgentCreateReq) -> Result<AgentFile, String> {
    let dir = user_agents_dir()?;
    let target = dir.join(format!("{}.org", req.slug));
    // Refuse to clobber an existing user-scope agent. The chat header's
    // "Create" path generates a unique stamped slug, so collisions are
    // rare and almost always a user mistake.
    if target.exists() {
        return Err(format!(
            "user-scope agent '{}' already exists — pick a different id",
            req.slug
        ));
    }
    write_agent(&req.slug, &req.source).await
}

#[derive(Deserialize)]
pub struct AgentUpdateReq {
    pub slug: String,
    pub source: String,
}

#[tauri::command]
pub async fn agents_update(req: AgentUpdateReq) -> Result<AgentFile, String> {
    // Update is just a write — no existence precheck. Callers (Settings
    // → Agents) confirm they're operating on a known-existing
    // user-scope file before invoking.
    write_agent(&req.slug, &req.source).await
}

#[tauri::command]
pub async fn agents_read(slug: String) -> Result<AgentFile, String> {
    validate_slug(&slug)?;
    let dir = user_agents_dir()?;
    let path = dir.join(format!("{slug}.org"));
    let source = fs::read_to_string(&path)
        .await
        .map_err(|e| format!("read {}: {e}", path.display()))?;
    Ok(AgentFile {
        slug,
        path: path.to_string_lossy().into_owned(),
        source,
    })
}

/// Patch one or more drawer properties on a user-scope agent's `.org`
/// file via oql-core's `Document::set_property` (parser-backed AST
/// mutation, NOT regex). Each (key, value) pair becomes a
/// `:KEY: value` line in the headline's `:PROPERTIES:` drawer — added
/// if missing, replaced if present. The whole file's existing content
/// (other properties, sub-headings, comments, file-level keywords) is
/// preserved byte-for-byte except for the property lines mutated here.
///
/// Why parser-backed: regex patching silently miscounted heading
/// boundaries (lost ALLOW_SPAWN / SPAWN_DEPTH / MAX_CHILDREN /
/// CAN_GRANT on Workhorse when the icon was edited). Parser-backed
/// mutation routes through orgize's AST and orgize's exact-range
/// replacements — same primitive `set_property` that oql-agent's
/// runtime uses to mutate agent files on its side. Single source of
/// truth.
///
/// `body` is intentionally NOT handled here — oql-core doesn't
/// expose `set_section_body` yet (see wb-shtl.6). Body edits fall
/// through to the existing `agents_update` whole-file write path
/// until that lands.
#[derive(Deserialize)]
pub struct AgentPatchReq {
    pub slug: String,
    /// Map of drawer property name → new value. Empty string signals
    /// "leave alone" (no-op). Property deletion isn't exposed by
    /// oql-core's set_property; edit the org file directly for v1.
    pub properties: BTreeMap<String, String>,
    /// Optional headline title text. When present, replaces the
    /// existing title; the agent's `:agent:` tag is preserved.
    /// Substrate gap (wb-shtl.6): set via string splice over the
    /// parser-serialized output until oql-core exposes set_title.
    pub title: Option<String>,
    /// Optional `** System prompt` section body. When present,
    /// replaces the existing body text (up to next sibling heading).
    /// Same substrate gap — string splice over serialized output.
    pub system_prompt: Option<String>,
}

#[tauri::command]
pub async fn agents_patch(req: AgentPatchReq) -> Result<AgentFile, String> {
    validate_slug(&req.slug)?;

    let dir = user_agents_dir()?;
    let path = dir.join(format!("{}.org", req.slug));
    let source = fs::read_to_string(&path)
        .await
        .map_err(|e| format!("read {}: {e}", path.display()))?;

    // Properties via oql-core — no regex, no risk of clobbering
    // sibling drawer entries or sub-headings.
    let mut doc = Document::parse(&source);
    for (key, value) in req.properties.iter() {
        if value.is_empty() {
            continue;
        }
        if key.eq_ignore_ascii_case("ID") {
            continue;
        }
        doc.set_property(&req.slug, key, value)
            .map_err(|e| format!("set_property({key}): {e:?}"))?;
    }
    let mut serialized = doc.serialize();

    // Title + body: substrate gap (wb-shtl.6). String splices over
    // the parser-serialized output are narrower than regex over the
    // whole file — orgize already canonicalized the headline shape,
    // so splice boundaries are predictable.
    if let Some(new_title) = req.title.as_deref() {
        serialized = splice_title(&serialized, new_title);
    }
    if let Some(new_body) = req.system_prompt.as_deref() {
        serialized = splice_system_prompt(&serialized, new_body);
    }

    fs::write(&path, serialized.as_bytes())
        .await
        .map_err(|e| format!("write {}: {e}", path.display()))?;

    Ok(AgentFile {
        slug: req.slug,
        path: path.to_string_lossy().into_owned(),
        source: serialized,
    })
}

/// Replace the title text of the first level-1 headline. Preserves
/// leading `* ` and trailing `:tag:` cluster. Falls through unchanged
/// if no headline is found (defensive — caller has already parsed via
/// oql-core, so it's there).
fn splice_title(src: &str, new_title: &str) -> String {
    let Some(start) = src.find("\n* ").map(|i| i + 1).or_else(|| {
        if src.starts_with("* ") { Some(0) } else { None }
    }) else {
        return src.to_string();
    };
    let after_stars = start + 2;
    let line_end = src[after_stars..]
        .find('\n')
        .map(|i| after_stars + i)
        .unwrap_or(src.len());
    let line = &src[after_stars..line_end];
    // Match a trailing `:tag1:tag2:` cluster (org tag syntax) so we
    // preserve it. orgize re-emits tags compactly; the cluster is
    // always at the end of the line.
    let tag_idx = find_tag_cluster_start(line);
    let trailing_tags = if let Some(i) = tag_idx {
        line[i..].trim_end().to_string()
    } else {
        String::new()
    };
    let new_line = if trailing_tags.is_empty() {
        new_title.trim().to_string()
    } else {
        format!("{}                                                          {}", new_title.trim(), trailing_tags)
    };
    let mut out = String::with_capacity(src.len() + new_line.len());
    out.push_str(&src[..after_stars]);
    out.push_str(&new_line);
    out.push_str(&src[line_end..]);
    out
}

fn find_tag_cluster_start(line: &str) -> Option<usize> {
    // Walk backwards from end. Tag cluster is `:tag1:tag2:` with
    // optional whitespace before. Each tag matches [a-zA-Z0-9_@-]+.
    let trimmed = line.trim_end();
    let bytes = trimmed.as_bytes();
    if !bytes.last().is_some_and(|&b| b == b':') {
        return None;
    }
    // Scan backwards for the start of the colon-separated cluster.
    let mut i = bytes.len();
    let mut in_tag = false;
    while i > 0 {
        let b = bytes[i - 1];
        if b == b':' {
            in_tag = !in_tag;
            i -= 1;
        } else if !in_tag {
            break;
        } else if b.is_ascii_alphanumeric() || b == b'_' || b == b'@' || b == b'-' {
            i -= 1;
        } else {
            // Cluster ended one position back.
            break;
        }
    }
    // Skip leading whitespace before the cluster on the title line.
    while i > 0 && (bytes[i - 1] == b' ' || bytes[i - 1] == b'\t') {
        i -= 1;
    }
    if i < bytes.len() && bytes[i..].iter().any(|&b| b == b':') {
        Some(i)
    } else {
        None
    }
}

/// Replace the body of the `** System prompt` subsection — text from
/// after the heading line up to the next sibling heading at the same
/// level or higher, or EOF. Bounded by literal heading-line matches
/// in the parser-serialized output.
fn splice_system_prompt(src: &str, new_body: &str) -> String {
    // Find `\n** System prompt` (or at start of string).
    let pat_with_lf = "\n** System prompt";
    let head_start = if let Some(i) = src.find(pat_with_lf) {
        i + 1
    } else if src.starts_with("** System prompt") {
        0
    } else {
        // No System prompt section — append one.
        let mut out = src.trim_end().to_string();
        out.push_str("\n\n** System prompt\n");
        out.push_str(new_body);
        if !out.ends_with('\n') {
            out.push('\n');
        }
        return out;
    };
    // Body starts after the first newline that follows the heading.
    let body_start = match src[head_start..].find('\n') {
        Some(i) => head_start + i + 1,
        None => return src.to_string(),
    };
    // Body ends at the next sibling heading (`\n** ` or `\n* `) that
    // is NOT a deeper level (`\n*** ...`). orgize-serialized output
    // uses canonical heading lines, so the literal match is reliable.
    let body_end = {
        let tail = &src[body_start..];
        let mut idx = None;
        let mut cursor = 0;
        while let Some(off) = tail[cursor..].find('\n') {
            let line_start = cursor + off + 1;
            if line_start >= tail.len() {
                break;
            }
            let after = &tail[line_start..];
            // Sibling-or-higher heading: starts with `* ` or `** ` (NOT `*** ` etc.).
            if after.starts_with("* ") || (after.starts_with("** ") && !after.starts_with("*** ")) {
                idx = Some(body_start + line_start);
                break;
            }
            cursor = line_start;
        }
        idx.unwrap_or(src.len())
    };
    let mut out = String::with_capacity(src.len() + new_body.len());
    out.push_str(&src[..body_start]);
    out.push_str(new_body);
    if !new_body.ends_with('\n') {
        out.push('\n');
    }
    out.push_str(&src[body_end..]);
    out
}

#[tauri::command]
pub async fn agents_delete(slug: String) -> Result<(), String> {
    validate_slug(&slug)?;
    let dir = user_agents_dir()?;
    let path = dir.join(format!("{slug}.org"));
    fs::remove_file(&path)
        .await
        .map_err(|e| format!("delete {}: {e}", path.display()))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slug_validation() {
        assert!(validate_slug("workhorse").is_ok());
        assert!(validate_slug("agent-creator").is_ok());
        assert!(validate_slug("a1").is_ok());
        assert!(validate_slug("").is_err());
        assert!(validate_slug("Workhorse").is_err()); // uppercase
        assert!(validate_slug("1agent").is_err()); // digit first
        assert!(validate_slug("agent_x").is_err()); // underscore
        assert!(validate_slug("../escape").is_err()); // path traversal attempt
    }

    #[test]
    fn source_validation() {
        let good = "* Title :agent:\n:PROPERTIES:\n:ID: foo\n:END:\n";
        assert!(validate_source(good).is_ok());

        assert!(validate_source("").is_err());
        assert!(validate_source("just text").is_err()); // no :agent:
        assert!(validate_source("* x :agent:\n").is_err()); // no :ID:
    }
}
