// Plain-JSON registries the shell persists under ~/.oql/desktop: bookmarks,
// themes, MCP servers, plugins. No secrets here (those go through keychain.rs),
// so a JSON index on disk is the whole story. Each registry follows the same
// load → mutate → atomic-write shape via paths::{read_json,write_json}.

use crate::paths;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

// ── Bookmarks ─────────────────────────────────────────────────────

fn bookmarks_path() -> PathBuf {
    paths::oql_desktop_dir().join("bookmarks.json")
}

#[derive(Serialize, Deserialize, Clone)]
pub struct Bookmark {
    pub id: String,
    pub title: String,
    pub path: String,
    /// 1..9 or null.
    pub command_slot: Option<u8>,
    pub created_at: u64,
}

#[derive(Serialize, Deserialize, Default)]
struct BookmarkIndex {
    bookmarks: Vec<Bookmark>,
}

fn load_bookmarks() -> Vec<Bookmark> {
    let mut idx: BookmarkIndex = paths::read_json(&bookmarks_path());
    idx.bookmarks.sort_by_key(|b| b.created_at);
    idx.bookmarks
}

fn save_bookmarks(bookmarks: Vec<Bookmark>) -> Result<(), String> {
    paths::write_json(&bookmarks_path(), &BookmarkIndex { bookmarks })
}

#[tauri::command]
pub fn bookmark_list() -> Vec<Bookmark> {
    load_bookmarks()
}

#[derive(Deserialize)]
pub struct BookmarkCreate {
    pub title: String,
    pub path: String,
    pub command_slot: Option<u8>,
}

#[tauri::command]
pub fn bookmark_create(req: BookmarkCreate) -> Result<Bookmark, String> {
    let mut bookmarks = load_bookmarks();
    // A slot is single-holder — evict the prior claimant.
    if let Some(slot) = req.command_slot {
        for b in bookmarks.iter_mut() {
            if b.command_slot == Some(slot) {
                b.command_slot = None;
            }
        }
    }
    let bm = Bookmark {
        id: uuid::Uuid::new_v4().to_string(),
        title: req.title,
        path: req.path,
        command_slot: req.command_slot,
        created_at: paths::now_ms(),
    };
    bookmarks.push(bm.clone());
    save_bookmarks(bookmarks)?;
    Ok(bm)
}

#[derive(Deserialize)]
pub struct BookmarkRename {
    pub id: String,
    pub title: String,
}

#[tauri::command]
pub fn bookmark_rename(req: BookmarkRename) -> Result<(), String> {
    let mut bookmarks = load_bookmarks();
    if let Some(b) = bookmarks.iter_mut().find(|b| b.id == req.id) {
        b.title = req.title;
    }
    save_bookmarks(bookmarks)
}

#[tauri::command]
pub fn bookmark_delete(id: String) -> Result<(), String> {
    let mut bookmarks = load_bookmarks();
    bookmarks.retain(|b| b.id != id);
    save_bookmarks(bookmarks)
}

#[derive(Deserialize)]
pub struct BookmarkSetSlot {
    pub id: String,
    pub slot: Option<u8>,
}

#[tauri::command]
pub fn bookmark_set_slot(req: BookmarkSetSlot) -> Result<(), String> {
    let mut bookmarks = load_bookmarks();
    if let Some(slot) = req.slot {
        for b in bookmarks.iter_mut() {
            if b.command_slot == Some(slot) {
                b.command_slot = None;
            }
        }
    }
    if let Some(b) = bookmarks.iter_mut().find(|b| b.id == req.id) {
        b.command_slot = req.slot;
    }
    save_bookmarks(bookmarks)
}

// ── Themes ────────────────────────────────────────────────────────

fn themes_path() -> PathBuf {
    paths::oql_desktop_dir().join("themes.json")
}
fn theme_active_path() -> PathBuf {
    paths::oql_desktop_dir().join("theme-active.json")
}

#[derive(Serialize, Deserialize, Clone)]
pub struct Theme {
    pub id: String,
    pub name: String,
    pub description: String,
    pub light_tokens: std::collections::BTreeMap<String, String>,
    pub dark_tokens: std::collections::BTreeMap<String, String>,
    pub builtin: bool,
    pub created_at: u64,
}

#[derive(Serialize, Deserialize, Default)]
struct ThemeIndex {
    themes: Vec<Theme>,
}

#[derive(Serialize, Deserialize, Default)]
struct ActivePointer {
    active_id: Option<String>,
}

#[derive(Serialize)]
pub struct ThemesSnapshot {
    pub active_id: Option<String>,
    pub themes: Vec<Theme>,
}

/// Seed the built-in themes if absent. Minimal token sets — the client merges
/// with app.css defaults, so we only define the canonical color tokens.
fn builtins() -> Vec<Theme> {
    let mut light = std::collections::BTreeMap::new();
    light.insert("color-page".into(), "#ffffff".into());
    light.insert("color-fg".into(), "#0a0a0a".into());
    light.insert("color-accent".into(), "#2563eb".into());
    let mut dark = std::collections::BTreeMap::new();
    dark.insert("color-page".into(), "#0a0a0a".into());
    dark.insert("color-fg".into(), "#f5f5f5".into());
    dark.insert("color-accent".into(), "#60a5fa".into());
    vec![Theme {
        id: "builtin-default".into(),
        name: "Default".into(),
        description: "The stock Workbooks palette.".into(),
        light_tokens: light,
        dark_tokens: dark,
        builtin: true,
        created_at: 0,
    }]
}

fn load_themes() -> Vec<Theme> {
    let mut idx: ThemeIndex = paths::read_json(&themes_path());
    // Merge built-ins (seed if absent) so the list always offers them.
    for b in builtins() {
        if !idx.themes.iter().any(|t| t.id == b.id) {
            idx.themes.push(b);
        }
    }
    idx.themes
}

fn save_user_themes(themes: &[Theme]) -> Result<(), String> {
    let user: Vec<Theme> = themes.iter().filter(|t| !t.builtin).cloned().collect();
    paths::write_json(&themes_path(), &ThemeIndex { themes: user })
}

#[tauri::command]
pub fn theme_list() -> ThemesSnapshot {
    let ptr: ActivePointer = paths::read_json(&theme_active_path());
    ThemesSnapshot {
        active_id: ptr.active_id,
        themes: load_themes(),
    }
}

#[tauri::command]
pub fn theme_set_active(id: Option<String>) -> Result<(), String> {
    paths::write_json(&theme_active_path(), &ActivePointer { active_id: id })
}

#[derive(Deserialize)]
pub struct ThemeCreate {
    pub name: String,
    pub description: String,
    pub light_tokens: std::collections::BTreeMap<String, String>,
    pub dark_tokens: std::collections::BTreeMap<String, String>,
}

#[tauri::command]
pub fn theme_create(req: ThemeCreate) -> Result<Theme, String> {
    let mut themes = load_themes();
    let t = Theme {
        id: uuid::Uuid::new_v4().to_string(),
        name: req.name,
        description: req.description,
        light_tokens: req.light_tokens,
        dark_tokens: req.dark_tokens,
        builtin: false,
        created_at: paths::now_ms(),
    };
    themes.push(t.clone());
    save_user_themes(&themes)?;
    Ok(t)
}

#[derive(Deserialize)]
pub struct ThemeUpdate {
    pub id: String,
    pub name: String,
    pub description: String,
    pub light_tokens: std::collections::BTreeMap<String, String>,
    pub dark_tokens: std::collections::BTreeMap<String, String>,
}

#[tauri::command]
pub fn theme_update(req: ThemeUpdate) -> Result<(), String> {
    let mut themes = load_themes();
    let Some(t) = themes.iter_mut().find(|t| t.id == req.id) else {
        return Err("theme not found".into());
    };
    if t.builtin {
        return Err("cannot edit a built-in theme".into());
    }
    t.name = req.name;
    t.description = req.description;
    t.light_tokens = req.light_tokens;
    t.dark_tokens = req.dark_tokens;
    save_user_themes(&themes)
}

#[tauri::command]
pub fn theme_delete(id: String) -> Result<(), String> {
    let mut themes = load_themes();
    themes.retain(|t| t.id != id || t.builtin);
    save_user_themes(&themes)?;
    let ptr: ActivePointer = paths::read_json(&theme_active_path());
    if ptr.active_id.as_deref() == Some(&id) {
        paths::write_json(&theme_active_path(), &ActivePointer { active_id: None })?;
    }
    Ok(())
}

// ── MCP servers ───────────────────────────────────────────────────

fn mcp_path() -> PathBuf {
    paths::oql_desktop_dir().join("mcp-servers.json")
}

#[derive(Serialize, Deserialize, Clone)]
pub struct McpServer {
    pub id: String,
    pub name: String,
    pub transport: String,
    pub command_or_url: String,
    pub args: Vec<String>,
    pub env: std::collections::BTreeMap<String, String>,
    pub enabled: bool,
    pub created_at: u64,
}

#[derive(Serialize, Deserialize, Default)]
struct McpIndex {
    servers: Vec<McpServer>,
}

fn load_mcp() -> Vec<McpServer> {
    let idx: McpIndex = paths::read_json(&mcp_path());
    idx.servers
}
fn save_mcp(servers: Vec<McpServer>) -> Result<(), String> {
    paths::write_json(&mcp_path(), &McpIndex { servers })
}

#[tauri::command]
pub fn mcp_list() -> Vec<McpServer> {
    load_mcp()
}

#[derive(Deserialize)]
pub struct McpCreate {
    pub name: String,
    pub transport: String,
    pub command_or_url: String,
    pub args: Vec<String>,
    pub env: std::collections::BTreeMap<String, String>,
    pub enabled: bool,
}

#[tauri::command]
pub fn mcp_create(req: McpCreate) -> Result<McpServer, String> {
    let mut servers = load_mcp();
    let s = McpServer {
        id: uuid::Uuid::new_v4().to_string(),
        name: req.name,
        transport: req.transport,
        command_or_url: req.command_or_url,
        args: req.args,
        env: req.env,
        enabled: req.enabled,
        created_at: paths::now_ms(),
    };
    servers.push(s.clone());
    save_mcp(servers)?;
    Ok(s)
}

#[derive(Deserialize)]
pub struct McpUpdate {
    pub id: String,
    pub name: String,
    pub transport: String,
    pub command_or_url: String,
    pub args: Vec<String>,
    pub env: std::collections::BTreeMap<String, String>,
    pub enabled: bool,
}

#[tauri::command]
pub fn mcp_update(req: McpUpdate) -> Result<McpServer, String> {
    let mut servers = load_mcp();
    let Some(s) = servers.iter_mut().find(|s| s.id == req.id) else {
        return Err("mcp server not found".into());
    };
    s.name = req.name;
    s.transport = req.transport;
    s.command_or_url = req.command_or_url;
    s.args = req.args;
    s.env = req.env;
    s.enabled = req.enabled;
    let updated = s.clone();
    save_mcp(servers)?;
    Ok(updated)
}

#[tauri::command]
pub fn mcp_delete(id: String) -> Result<(), String> {
    let mut servers = load_mcp();
    servers.retain(|s| s.id != id);
    save_mcp(servers)
}

// ── Plugins ───────────────────────────────────────────────────────

fn plugins_path() -> PathBuf {
    paths::oql_desktop_dir().join("plugins.json")
}

#[derive(Serialize, Deserialize, Clone)]
pub struct Plugin {
    pub id: String,
    pub name: String,
    pub source: String,
    pub version: String,
    pub enabled: bool,
    pub installed_at: u64,
}

#[derive(Serialize, Deserialize, Default)]
struct PluginIndex {
    plugins: Vec<Plugin>,
}

fn load_plugins() -> Vec<Plugin> {
    let idx: PluginIndex = paths::read_json(&plugins_path());
    idx.plugins
}
fn save_plugins(plugins: Vec<Plugin>) -> Result<(), String> {
    paths::write_json(&plugins_path(), &PluginIndex { plugins })
}

#[tauri::command]
pub fn plugins_list() -> Vec<Plugin> {
    load_plugins()
}

#[derive(Deserialize)]
pub struct PluginCreate {
    pub name: String,
    pub source: String,
    pub version: String,
    pub enabled: bool,
}

#[tauri::command]
pub fn plugins_install(req: PluginCreate) -> Result<Plugin, String> {
    let mut plugins = load_plugins();
    let p = Plugin {
        id: uuid::Uuid::new_v4().to_string(),
        name: req.name,
        source: req.source,
        version: req.version,
        enabled: req.enabled,
        installed_at: paths::now_ms(),
    };
    plugins.push(p.clone());
    save_plugins(plugins)?;
    Ok(p)
}

#[derive(Deserialize)]
pub struct PluginSetEnabled {
    pub id: String,
    pub enabled: bool,
}

#[tauri::command]
pub fn plugins_set_enabled(req: PluginSetEnabled) -> Result<(), String> {
    let mut plugins = load_plugins();
    if let Some(p) = plugins.iter_mut().find(|p| p.id == req.id) {
        p.enabled = req.enabled;
    }
    save_plugins(plugins)
}

#[tauri::command]
pub fn plugins_remove(id: String) -> Result<(), String> {
    let mut plugins = load_plugins();
    plugins.retain(|p| p.id != id);
    save_plugins(plugins)
}
