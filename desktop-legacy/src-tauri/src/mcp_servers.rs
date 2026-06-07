// MCP server registry (wb-i38o.6 §2).
//
// Persists the user's MCP server configs at `~/.oql/desktop/mcp-servers.json`.
// The oql-agent doesn't read this file yet — wiring it up server-side
// is a follow-up. This module's job is to land the UI-visible state +
// the JSON schema so a future agent-side consumer can pick the file
// up without rework.
//
// Schema (array):
//   [
//     {
//       "id":              "<uuid-ish>",
//       "name":            "github",
//       "transport":       "stdio" | "http",
//       "command_or_url":  "npx" | "https://mcp.example.com/sse",
//       "args":            ["-y", "@modelcontextprotocol/server-github"],
//       "env":             { "GITHUB_TOKEN": "..." },
//       "enabled":         true,
//       "created_at":      <unix-millis>
//     },
//     ...
//   ]
//
// For stdio: `command_or_url` is the executable; `args` is forwarded as
// argv; `env` is a string→string map of process env to set.
// For http:  `command_or_url` is the URL; args/env are unused but kept
// in the schema so a transport switch doesn't lose data.

#![allow(clippy::module_name_repetitions)]

use std::collections::BTreeMap;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::config_paths::desktop_root;
use crate::org_kv::{self, OrgEntry};

const MCP_FILE: &str = "mcp-servers.org";
const SCHEMA: &str = "mcp-servers.v1";

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum McpTransport {
    Stdio,
    Http,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct McpServer {
    pub id: String,
    pub name: String,
    pub transport: McpTransport,
    pub command_or_url: String,
    #[serde(default)]
    pub args: Vec<String>,
    #[serde(default)]
    pub env: BTreeMap<String, String>,
    pub enabled: bool,
    pub created_at: i64,
}

fn mcp_path() -> PathBuf {
    desktop_root().join(MCP_FILE)
}

fn validate(server: &McpServer) -> Result<(), String> {
    if server.name.trim().is_empty() {
        return Err("server name cannot be empty".into());
    }
    if server.name.len() > 64 {
        return Err("server name must be <= 64 chars".into());
    }
    if server.command_or_url.trim().is_empty() {
        return match server.transport {
            McpTransport::Stdio => Err("command cannot be empty for stdio transport".into()),
            McpTransport::Http => Err("URL cannot be empty for http transport".into()),
        };
    }
    if matches!(server.transport, McpTransport::Http) {
        let u = server.command_or_url.trim();
        if !(u.starts_with("http://") || u.starts_with("https://")) {
            return Err("http transport URL must start with http:// or https://".into());
        }
    }
    Ok(())
}

impl McpServer {
    fn from_entry(e: &OrgEntry) -> Option<Self> {
        let transport = match e.get("TRANSPORT")? {
            "stdio" => McpTransport::Stdio,
            "http" => McpTransport::Http,
            _ => return None,
        };
        let args: Vec<String> = e
            .get("ARGS")
            .and_then(|s| serde_json::from_str(s).ok())
            .unwrap_or_default();
        let env: BTreeMap<String, String> = e
            .get("ENV")
            .and_then(|s| serde_json::from_str(s).ok())
            .unwrap_or_default();
        Some(McpServer {
            id: e.get("ID")?.to_string(),
            name: e.title.clone(),
            transport,
            command_or_url: e.get("COMMAND_OR_URL")?.to_string(),
            args,
            env,
            enabled: e.get("ENABLED").map(|v| v == "true").unwrap_or(true),
            created_at: e.get_i64("CREATED_AT").unwrap_or(0),
        })
    }

    fn to_entry(&self) -> OrgEntry {
        let transport = match self.transport {
            McpTransport::Stdio => "stdio",
            McpTransport::Http => "http",
        };
        let mut e = OrgEntry::new(self.name.clone())
            .with("ID", self.id.clone())
            .with("TRANSPORT", transport)
            .with("COMMAND_OR_URL", self.command_or_url.clone())
            .with("ENABLED", if self.enabled { "true" } else { "false" })
            .with("CREATED_AT", self.created_at.to_string());
        if !self.args.is_empty() {
            e = e.with("ARGS", serde_json::to_string(&self.args).unwrap_or_default());
        }
        if !self.env.is_empty() {
            e = e.with("ENV", serde_json::to_string(&self.env).unwrap_or_default());
        }
        e
    }
}

async fn read_all() -> Result<Vec<McpServer>, String> {
    let entries = org_kv::read_entries(&mcp_path(), SCHEMA).await?;
    Ok(entries.iter().filter_map(McpServer::from_entry).collect())
}

async fn write_all(servers: &[McpServer]) -> Result<(), String> {
    let entries: Vec<OrgEntry> = servers.iter().map(McpServer::to_entry).collect();
    org_kv::write_entries(&mcp_path(), SCHEMA, &entries).await
}

fn new_id() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("m_{:x}", nanos)
}

fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

// ── Tauri commands ──────────────────────────────────────────────────

#[tauri::command]
pub async fn mcp_list() -> Result<Vec<McpServer>, String> {
    let mut all = read_all().await?;
    all.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(all)
}

#[derive(Deserialize)]
pub struct McpCreate {
    pub name: String,
    pub transport: McpTransport,
    pub command_or_url: String,
    #[serde(default)]
    pub args: Vec<String>,
    #[serde(default)]
    pub env: BTreeMap<String, String>,
    #[serde(default = "default_enabled")]
    pub enabled: bool,
}

fn default_enabled() -> bool {
    true
}

#[tauri::command]
pub async fn mcp_create(req: McpCreate) -> Result<McpServer, String> {
    let server = McpServer {
        id: new_id(),
        name: req.name.trim().to_string(),
        transport: req.transport,
        command_or_url: req.command_or_url.trim().to_string(),
        args: req.args,
        env: req.env,
        enabled: req.enabled,
        created_at: now_ms(),
    };
    validate(&server)?;
    let mut all = read_all().await?;
    all.push(server.clone());
    write_all(&all).await?;
    Ok(server)
}

#[derive(Deserialize)]
pub struct McpUpdate {
    pub id: String,
    pub name: String,
    pub transport: McpTransport,
    pub command_or_url: String,
    #[serde(default)]
    pub args: Vec<String>,
    #[serde(default)]
    pub env: BTreeMap<String, String>,
    pub enabled: bool,
}

#[tauri::command]
pub async fn mcp_update(req: McpUpdate) -> Result<McpServer, String> {
    let mut all = read_all().await?;
    let s = all
        .iter_mut()
        .find(|s| s.id == req.id)
        .ok_or_else(|| format!("no mcp server with id {}", req.id))?;
    s.name = req.name.trim().to_string();
    s.transport = req.transport;
    s.command_or_url = req.command_or_url.trim().to_string();
    s.args = req.args;
    s.env = req.env;
    s.enabled = req.enabled;
    validate(s)?;
    let updated = s.clone();
    write_all(&all).await?;
    Ok(updated)
}

#[tauri::command]
pub async fn mcp_delete(id: String) -> Result<(), String> {
    let mut all = read_all().await?;
    let before = all.len();
    all.retain(|s| s.id != id);
    if all.len() == before {
        return Err(format!("no mcp server with id {id}"));
    }
    write_all(&all).await
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tempdir_str() -> String {
        let mut p = std::env::temp_dir();
        p.push(format!(
            "oql-desktop-mcp-test-{}-{}",
            std::process::id(),
            uniq()
        ));
        p.to_string_lossy().into_owned()
    }

    fn uniq() -> u64 {
        use std::time::{SystemTime, UNIX_EPOCH};
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos() as u64
    }

    #[tokio::test(flavor = "current_thread")]
    async fn create_update_delete_roundtrip() {
        let tmp = tempdir_str();
        std::env::set_var("OQL_DESKTOP_HOME", &tmp);
        std::fs::create_dir_all(&tmp).unwrap();

        let s = mcp_create(McpCreate {
            name: "github".into(),
            transport: McpTransport::Stdio,
            command_or_url: "npx".into(),
            args: vec!["-y".into(), "@modelcontextprotocol/server-github".into()],
            env: BTreeMap::new(),
            enabled: true,
        })
        .await
        .unwrap();

        let listed = mcp_list().await.unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].name, "github");

        mcp_update(McpUpdate {
            id: s.id.clone(),
            name: "gh".into(),
            transport: McpTransport::Stdio,
            command_or_url: "npx".into(),
            args: vec![],
            env: BTreeMap::new(),
            enabled: false,
        })
        .await
        .unwrap();
        let listed = mcp_list().await.unwrap();
        assert_eq!(listed[0].name, "gh");
        assert!(!listed[0].enabled);

        mcp_delete(s.id).await.unwrap();
        assert!(mcp_list().await.unwrap().is_empty());

        std::env::remove_var("OQL_DESKTOP_HOME");
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn http_url_validated() {
        let tmp = tempdir_str();
        std::env::set_var("OQL_DESKTOP_HOME", &tmp);
        std::fs::create_dir_all(&tmp).unwrap();

        let err = mcp_create(McpCreate {
            name: "remote".into(),
            transport: McpTransport::Http,
            command_or_url: "not-a-url".into(),
            args: vec![],
            env: BTreeMap::new(),
            enabled: true,
        })
        .await
        .unwrap_err();
        assert!(err.contains("http://"), "got: {err}");

        std::env::remove_var("OQL_DESKTOP_HOME");
        let _ = std::fs::remove_dir_all(&tmp);
    }
}
