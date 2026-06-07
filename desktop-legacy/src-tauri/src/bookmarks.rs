// Bookmarks — quick-jump shortcuts to files anywhere across the
// workspace. Each can be assigned to ⌘1..⌘9 for keyboard jumps.
//
// On disk: `~/.oql/desktop/bookmarks.org`. Each bookmark is one
// top-level heading; structured fields live in the `:PROPERTIES:`
// drawer. Format chosen so agents read/edit the same substrate as
// the rest of the OQL-managed system without a JSON ceremony.
// See `org_kv.rs` for the helper.

#![allow(clippy::module_name_repetitions)]

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::config_paths::desktop_root;
use crate::org_kv::{self, OrgEntry};

const BOOKMARKS_FILE: &str = "bookmarks.org";
const SCHEMA: &str = "bookmarks.v1";

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Bookmark {
    pub id: String,
    pub title: String,
    pub path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command_slot: Option<u8>,
    pub created_at: i64,
}

fn bookmarks_path() -> PathBuf {
    desktop_root().join(BOOKMARKS_FILE)
}

impl Bookmark {
    fn from_entry(e: &OrgEntry) -> Option<Self> {
        Some(Bookmark {
            id: e.get("ID")?.to_string(),
            title: e.title.clone(),
            path: e.get("PATH")?.to_string(),
            command_slot: e.get_u8("COMMAND_SLOT"),
            created_at: e.get_i64("CREATED_AT").unwrap_or(0),
        })
    }

    fn to_entry(&self) -> OrgEntry {
        let mut e = OrgEntry::new(self.title.clone())
            .with("ID", self.id.clone())
            .with("PATH", self.path.clone())
            .with("CREATED_AT", self.created_at.to_string());
        if let Some(slot) = self.command_slot {
            e = e.with("COMMAND_SLOT", slot.to_string());
        }
        e
    }
}

async fn read_all() -> Result<Vec<Bookmark>, String> {
    let entries = org_kv::read_entries(&bookmarks_path(), SCHEMA).await?;
    Ok(entries.iter().filter_map(Bookmark::from_entry).collect())
}

async fn write_all(bookmarks: &[Bookmark]) -> Result<(), String> {
    let entries: Vec<OrgEntry> = bookmarks.iter().map(Bookmark::to_entry).collect();
    org_kv::write_entries(&bookmarks_path(), SCHEMA, &entries).await
}

fn new_id() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("bm_{:x}", nanos)
}

fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn validate_slot(slot: Option<u8>) -> Result<(), String> {
    if let Some(s) = slot {
        if !(1..=9).contains(&s) {
            return Err(format!("command slot must be 1..9 (got {s})"));
        }
    }
    Ok(())
}

// ── Tauri commands ──────────────────────────────────────────────────

#[tauri::command]
pub async fn bookmarks_list() -> Result<Vec<Bookmark>, String> {
    let mut all = read_all().await?;
    // Slot-assigned first (sorted by slot), then by recency.
    all.sort_by(|a, b| match (a.command_slot, b.command_slot) {
        (Some(x), Some(y)) => x.cmp(&y),
        (Some(_), None) => std::cmp::Ordering::Less,
        (None, Some(_)) => std::cmp::Ordering::Greater,
        (None, None) => b.created_at.cmp(&a.created_at),
    });
    Ok(all)
}

#[derive(Deserialize)]
pub struct BookmarkCreate {
    pub title: String,
    pub path: String,
    #[serde(default)]
    pub command_slot: Option<u8>,
}

#[tauri::command]
pub async fn bookmarks_create(req: BookmarkCreate) -> Result<Bookmark, String> {
    if req.title.trim().is_empty() {
        return Err("title is required".to_string());
    }
    if req.path.trim().is_empty() {
        return Err("path is required".to_string());
    }
    validate_slot(req.command_slot)?;
    let mut all = read_all().await?;
    if let Some(slot) = req.command_slot {
        for b in all.iter_mut() {
            if b.command_slot == Some(slot) {
                b.command_slot = None;
            }
        }
    }
    let b = Bookmark {
        id: new_id(),
        title: req.title.trim().to_string(),
        path: req.path.trim().to_string(),
        command_slot: req.command_slot,
        created_at: now_ms(),
    };
    all.push(b.clone());
    write_all(&all).await?;
    Ok(b)
}

#[derive(Deserialize)]
pub struct BookmarkUpdate {
    pub id: String,
    pub title: String,
}

#[tauri::command]
pub async fn bookmarks_update(req: BookmarkUpdate) -> Result<(), String> {
    let mut all = read_all().await?;
    let b = all
        .iter_mut()
        .find(|b| b.id == req.id)
        .ok_or_else(|| format!("no bookmark with id {}", req.id))?;
    if req.title.trim().is_empty() {
        return Err("title is required".to_string());
    }
    b.title = req.title.trim().to_string();
    write_all(&all).await?;
    Ok(())
}

#[tauri::command]
pub async fn bookmarks_delete(id: String) -> Result<(), String> {
    let mut all = read_all().await?;
    let before = all.len();
    all.retain(|b| b.id != id);
    if all.len() == before {
        return Err(format!("no bookmark with id {id}"));
    }
    write_all(&all).await?;
    Ok(())
}

#[derive(Deserialize)]
pub struct BookmarkSetSlot {
    pub id: String,
    /// 1..9 to assign, or null to clear.
    pub slot: Option<u8>,
}

#[tauri::command]
pub async fn bookmarks_set_slot(req: BookmarkSetSlot) -> Result<(), String> {
    validate_slot(req.slot)?;
    let mut all = read_all().await?;
    if !all.iter().any(|b| b.id == req.id) {
        return Err(format!("no bookmark with id {}", req.id));
    }
    if let Some(slot) = req.slot {
        for b in all.iter_mut() {
            if b.id != req.id && b.command_slot == Some(slot) {
                b.command_slot = None;
            }
        }
    }
    let b = all.iter_mut().find(|b| b.id == req.id).unwrap();
    b.command_slot = req.slot;
    write_all(&all).await?;
    Ok(())
}
