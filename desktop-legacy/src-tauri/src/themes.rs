// Themes — named collections of CSS custom-property values applied to
// `:root` at runtime to skin the desktop. The same on-disk shape will
// later power a workbook SDK (a workbook can read the host's active
// theme or override with its own) — see docs/canonical-model.md.
//
// On disk: `~/.oql/desktop/themes.org`. One top-level heading per
// theme; the token sets live in JSON-encoded properties because
// they're naturally maps with 20+ entries. The `#+ACTIVE:` keyword
// at the file header carries the currently-active theme id; falls
// back to `theme_default` when unset.
//
// Built-in themes are seeded into the file on first read if it
// doesn't exist. They're flagged `:builtin: true` so the UI can't
// delete them.

#![allow(clippy::module_name_repetitions)]

use std::collections::BTreeMap;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use tokio::fs;

use crate::config_paths::desktop_root;
use crate::org_kv::{self, OrgEntry};

const THEMES_FILE: &str = "themes.org";
const SCHEMA: &str = "themes.v1";
const ACTIVE_KEYWORD: &str = "#+ACTIVE:";

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Theme {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub light_tokens: BTreeMap<String, String>,
    #[serde(default)]
    pub dark_tokens: BTreeMap<String, String>,
    #[serde(default)]
    pub builtin: bool,
    pub created_at: i64,
}

impl Theme {
    fn from_entry(e: &OrgEntry) -> Option<Self> {
        let light_tokens: BTreeMap<String, String> = e
            .get("LIGHT_TOKENS")
            .and_then(|s| serde_json::from_str(s).ok())
            .unwrap_or_default();
        let dark_tokens: BTreeMap<String, String> = e
            .get("DARK_TOKENS")
            .and_then(|s| serde_json::from_str(s).ok())
            .unwrap_or_default();
        Some(Theme {
            id: e.get("ID")?.to_string(),
            name: e.title.clone(),
            description: e.get("DESCRIPTION").unwrap_or("").to_string(),
            light_tokens,
            dark_tokens,
            builtin: e.get("BUILTIN").map(|v| v == "true").unwrap_or(false),
            created_at: e.get_i64("CREATED_AT").unwrap_or(0),
        })
    }

    fn to_entry(&self) -> OrgEntry {
        let mut e = OrgEntry::new(self.name.clone())
            .with("ID", self.id.clone())
            .with("CREATED_AT", self.created_at.to_string());
        if !self.description.is_empty() {
            e = e.with("DESCRIPTION", self.description.clone());
        }
        if self.builtin {
            e = e.with("BUILTIN", "true");
        }
        if !self.light_tokens.is_empty() {
            e = e.with(
                "LIGHT_TOKENS",
                serde_json::to_string(&self.light_tokens).unwrap_or_default(),
            );
        }
        if !self.dark_tokens.is_empty() {
            e = e.with(
                "DARK_TOKENS",
                serde_json::to_string(&self.dark_tokens).unwrap_or_default(),
            );
        }
        e
    }
}

fn themes_path() -> PathBuf {
    desktop_root().join(THEMES_FILE)
}

async fn read_file() -> Result<(Option<String>, Vec<Theme>), String> {
    let path = themes_path();
    let raw = match fs::read_to_string(&path).await {
        Ok(s) => Some(s),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
        Err(e) => return Err(format!("read {THEMES_FILE}: {e}")),
    };
    if raw.is_none() {
        // First run — seed builtins.
        let builtins = builtin_themes();
        let active = builtins.first().map(|t| t.id.clone());
        write_file(&active, &builtins).await?;
        return Ok((active, builtins));
    }
    let active = parse_active(raw.as_deref().unwrap_or(""));
    let entries = org_kv::read_entries(&path, SCHEMA).await?;
    let mut themes: Vec<Theme> = entries.iter().filter_map(Theme::from_entry).collect();

    // Merge missing builtins on read. When we add a new built-in
    // theme to the canonical list, existing installs pick it up on
    // their next launch without losing the user's custom themes /
    // active-id. Builtins are addressed by their stable `id`.
    use std::collections::HashSet;
    let existing: HashSet<String> = themes.iter().map(|t| t.id.clone()).collect();
    let mut changed = false;
    for b in builtin_themes() {
        if !existing.contains(&b.id) {
            themes.push(b);
            changed = true;
        }
    }
    if changed {
        write_file(&active, &themes).await?;
    }
    Ok((active, themes))
}

async fn write_file(active: &Option<String>, themes: &[Theme]) -> Result<(), String> {
    let entries: Vec<OrgEntry> = themes.iter().map(Theme::to_entry).collect();
    let body = render(active, &entries);
    let path = themes_path();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .await
            .map_err(|e| format!("mkdir {}: {e}", parent.display()))?;
    }
    let tmp = path.with_extension("org.tmp");
    fs::write(&tmp, body)
        .await
        .map_err(|e| format!("write tmp: {e}"))?;
    fs::rename(&tmp, &path)
        .await
        .map_err(|e| format!("rename: {e}"))?;
    Ok(())
}

fn render(active: &Option<String>, entries: &[OrgEntry]) -> String {
    let mut out = String::new();
    out.push_str("#+SCHEMA: ");
    out.push_str(SCHEMA);
    out.push('\n');
    out.push_str(ACTIVE_KEYWORD);
    out.push(' ');
    if let Some(a) = active {
        out.push_str(a);
    }
    out.push_str("\n\n");
    for e in entries {
        out.push_str("* ");
        out.push_str(&e.title);
        out.push('\n');
        if !e.properties.is_empty() {
            out.push_str(":PROPERTIES:\n");
            for (k, v) in &e.properties {
                out.push(':');
                out.push_str(&k.to_lowercase());
                out.push_str(": ");
                out.push_str(v);
                out.push('\n');
            }
            out.push_str(":END:\n");
        }
        out.push('\n');
    }
    out
}

fn parse_active(src: &str) -> Option<String> {
    for line in src.lines().take(20) {
        let t = line.trim();
        if let Some(rest) = t.strip_prefix(ACTIVE_KEYWORD) {
            let v = rest.trim();
            return if v.is_empty() {
                None
            } else {
                Some(v.to_string())
            };
        }
        if t.starts_with("* ") {
            break;
        }
    }
    None
}

fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn new_id() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("t_{:x}", nanos)
}

/// Canonical named-theme palettes, embedded at compile time. Single
/// source of truth: desktop/src-tauri/themes.toml (desktop is the only
/// consumer; relocated from the deleted theme-tokens package, wb-lcfa.2).
const BUILTIN_THEMES_TOML: &str = include_str!("../themes.toml");

#[derive(Deserialize)]
struct BuiltinThemesFile {
    theme: Vec<BuiltinThemeEntry>,
}

#[derive(Deserialize)]
struct BuiltinThemeEntry {
    id: String,
    name: String,
    #[serde(default)]
    description: String,
    #[serde(default)]
    light: BTreeMap<String, String>,
    #[serde(default)]
    dark: BTreeMap<String, String>,
}

/// Built-in themes seeded on first read. Parsed from the embedded
/// canonical TOML; panics only if that vendored file is malformed,
/// which is a build-time-fixed defect, not a runtime condition.
fn builtin_themes() -> Vec<Theme> {
    let now = now_ms();
    let parsed: BuiltinThemesFile = toml::from_str(BUILTIN_THEMES_TOML)
        .expect("canonical themes.toml is malformed");
    parsed
        .theme
        .into_iter()
        .map(|t| Theme {
            id: t.id,
            name: t.name,
            description: t.description,
            light_tokens: t.light,
            dark_tokens: t.dark,
            builtin: true,
            created_at: now,
        })
        .collect()
}

// ── Tauri commands ──────────────────────────────────────────────────

#[derive(Serialize)]
pub struct ThemesSnapshot {
    pub active_id: Option<String>,
    pub themes: Vec<Theme>,
}

#[tauri::command]
pub async fn themes_list() -> Result<ThemesSnapshot, String> {
    let (active_id, themes) = read_file().await?;
    Ok(ThemesSnapshot { active_id, themes })
}

#[tauri::command]
pub async fn themes_set_active(id: Option<String>) -> Result<(), String> {
    let (_, themes) = read_file().await?;
    if let Some(ref id) = id {
        if !themes.iter().any(|t| &t.id == id) {
            return Err(format!("no theme with id {id}"));
        }
    }
    write_file(&id, &themes).await?;
    Ok(())
}

#[derive(Deserialize)]
pub struct ThemeCreate {
    pub name: String,
    #[serde(default)]
    pub description: String,
    pub light_tokens: BTreeMap<String, String>,
    pub dark_tokens: BTreeMap<String, String>,
}

#[tauri::command]
pub async fn themes_create(req: ThemeCreate) -> Result<Theme, String> {
    if req.name.trim().is_empty() {
        return Err("theme name is required".into());
    }
    let t = Theme {
        id: new_id(),
        name: req.name.trim().to_string(),
        description: req.description,
        light_tokens: req.light_tokens,
        dark_tokens: req.dark_tokens,
        builtin: false,
        created_at: now_ms(),
    };
    let (active, mut themes) = read_file().await?;
    themes.push(t.clone());
    write_file(&active, &themes).await?;
    Ok(t)
}

#[derive(Deserialize)]
pub struct ThemeUpdate {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub description: String,
    pub light_tokens: BTreeMap<String, String>,
    pub dark_tokens: BTreeMap<String, String>,
}

#[tauri::command]
pub async fn themes_update(req: ThemeUpdate) -> Result<(), String> {
    let (active, mut themes) = read_file().await?;
    let t = themes
        .iter_mut()
        .find(|t| t.id == req.id)
        .ok_or_else(|| format!("no theme with id {}", req.id))?;
    if t.builtin {
        return Err("built-in themes cannot be edited (clone first)".into());
    }
    t.name = req.name.trim().to_string();
    t.description = req.description;
    t.light_tokens = req.light_tokens;
    t.dark_tokens = req.dark_tokens;
    write_file(&active, &themes).await?;
    Ok(())
}

#[tauri::command]
pub async fn themes_delete(id: String) -> Result<(), String> {
    let (mut active, mut themes) = read_file().await?;
    let Some(idx) = themes.iter().position(|t| t.id == id) else {
        return Err(format!("no theme with id {id}"));
    };
    if themes[idx].builtin {
        return Err("built-in themes cannot be deleted".into());
    }
    themes.remove(idx);
    if active.as_deref() == Some(id.as_str()) {
        active = themes.first().map(|t| t.id.clone());
    }
    write_file(&active, &themes).await?;
    Ok(())
}
