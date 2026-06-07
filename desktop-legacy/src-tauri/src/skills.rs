// Skills registry — which agent skills are installed + where they
// apply.
//
// A *skill* is a documented bundle of agent-callable capabilities
// (Composio's "execute_action" tool, Claude Code's "invoke" tool, the
// Google Workspace `gws` shell wrapper, etc.). Skills are loaded by
// the sidecar at agent-invocation time and become part of the system
// prompt + tool registry the LLM sees.
//
// Two flavors of skill end up in the registry:
//
//   1. **Auto-imported from connections** — when a user connects
//      Composio, we drop a "Composio actions" skill into the
//      registry, scoped wherever the connection is scoped. Delete
//      the connection, the skill goes with it. Identified by
//      `source = "<service>"`.
//
//   2. **Manually added** — user adds a custom skill via the UI
//      (deferred for v1; the storage shape supports it). Identified
//      by `source = "manual"`.
//
// Scope mirrors `env_vars.rs`:
//
//   - `user`      → available to every agent run regardless of where
//   - `workspace` → only when the agent is acting inside a specific
//                   workspace (`scope_target = <workspace_id>`)
//   - `package`   → only when the agent's working package matches
//                   (`scope_target = <package_name>`)
//
// On-disk:
//
//   ~/.oql/desktop/skills.org
//
// One org entry per skill; properties carry the metadata. The Elixir
// sidecar reads this directly at runtime to compose the tool list for
// an agent invocation — there's no encryption layer (these aren't
// secrets) and no live-push (the sidecar reads on demand).

#![allow(clippy::module_name_repetitions)]

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::config_paths::desktop_root;
use crate::org_kv::{self, OrgEntry};

const SKILLS_FILE: &str = "skills.org";
const SCHEMA: &str = "skills.v1";

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum SkillScope {
    User,
    Workspace,
    Package,
}

impl SkillScope {
    fn as_str(self) -> &'static str {
        match self {
            Self::User => "user",
            Self::Workspace => "workspace",
            Self::Package => "package",
        }
    }
    fn from_str(s: &str) -> Option<Self> {
        match s {
            "user" => Some(Self::User),
            "workspace" => Some(Self::Workspace),
            "package" => Some(Self::Package),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Skill {
    pub id: String,
    /// Human-readable name. Renders in the Skills tab list.
    pub name: String,
    /// Short blurb shown in the row's hover tooltip + below the name.
    pub description: String,
    /// Origin tag — service slug for auto-imported skills, "manual"
    /// for hand-added ones.
    pub source: String,
    /// Underlying app slug for Composio-imported skills (`slack`,
    /// `gmail`, …). Empty for non-Composio sources.
    pub app: Option<String>,
    /// Scope chip rendered next to the row.
    pub scope: SkillScope,
    pub workspace_id: Option<String>,
    pub package_name: Option<String>,
    /// Relative path to the SKILL.md describing this skill in detail.
    /// Resolved by the sidecar at runtime; empty for v1 stubs.
    pub skill_md_path: Option<String>,
    pub created_at: i64,
}

impl Skill {
    fn from_entry(e: &OrgEntry) -> Option<Self> {
        let scope = SkillScope::from_str(e.get("SCOPE")?)?;
        Some(Skill {
            id: e.get("ID")?.to_string(),
            name: e.title.clone(),
            description: e.get("DESCRIPTION").map(|s| s.to_string()).unwrap_or_default(),
            source: e.get("SOURCE")?.to_string(),
            app: e.get("APP").map(|s| s.to_string()),
            scope,
            workspace_id: e.get("WORKSPACE_ID").map(|s| s.to_string()),
            package_name: e.get("PACKAGE_NAME").map(|s| s.to_string()),
            skill_md_path: e.get("SKILL_MD_PATH").map(|s| s.to_string()),
            created_at: e.get_i64("CREATED_AT").unwrap_or(0),
        })
    }

    fn to_entry(&self) -> OrgEntry {
        let mut e = OrgEntry::new(self.name.clone())
            .with("ID", self.id.clone())
            .with("SOURCE", self.source.clone())
            .with("SCOPE", self.scope.as_str())
            .with("CREATED_AT", self.created_at.to_string());
        if !self.description.is_empty() {
            e = e.with("DESCRIPTION", self.description.clone());
        }
        if let Some(a) = &self.app {
            e = e.with("APP", a.clone());
        }
        if let Some(w) = &self.workspace_id {
            e = e.with("WORKSPACE_ID", w.clone());
        }
        if let Some(p) = &self.package_name {
            e = e.with("PACKAGE_NAME", p.clone());
        }
        if let Some(path) = &self.skill_md_path {
            e = e.with("SKILL_MD_PATH", path.clone());
        }
        e
    }
}

fn skills_path() -> PathBuf {
    desktop_root().join(SKILLS_FILE)
}

async fn read_all() -> Result<Vec<Skill>, String> {
    let entries = org_kv::read_entries(&skills_path(), SCHEMA).await?;
    Ok(entries.iter().filter_map(Skill::from_entry).collect())
}

async fn write_all(skills: &[Skill]) -> Result<(), String> {
    let entries: Vec<OrgEntry> = skills.iter().map(Skill::to_entry).collect();
    org_kv::write_entries(&skills_path(), SCHEMA, &entries).await?;
    Ok(())
}

fn new_id() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("sk_{:x}", nanos)
}

fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

// ── Connection-driven propagation ─────────────────────────────────
//
// Called from `connections.rs` after a successful connect. Each
// integration contributes one skill entry at User scope by default;
// the user can re-scope from the Skills tab. Idempotent: if a skill
// already exists for the same (source, app) pair we update it
// rather than duplicate.

#[derive(Clone, Debug)]
pub struct PropagationSpec {
    pub source: String,
    pub app: Option<String>,
    pub name: String,
    pub description: String,
}

/// Built-in propagation specs per service. The handful of integrations
/// we ship with hard-coded skill metadata; richer per-app vocabulary
/// (e.g. Composio's per-toolkit skill bundles) lands incrementally.
pub fn propagation_spec_for_service(service: &str) -> Option<PropagationSpec> {
    match service {
        "composio" => Some(PropagationSpec {
            source: "composio".into(),
            app: None,
            name: "Composio actions".into(),
            description:
                "Execute actions on any of your connected Composio apps via the Composio SDK."
                    .into(),
        }),
        "doppler" => Some(PropagationSpec {
            source: "doppler".into(),
            app: None,
            name: "Doppler secret sync".into(),
            description: "Read and sync project/stage secrets from Doppler.".into(),
        }),
        "fal" => Some(PropagationSpec {
            source: "fal".into(),
            app: None,
            name: "fal.ai generation".into(),
            description:
                "Generate images, video, audio, music, speech, and 3D via fal.ai's hosted models."
                    .into(),
        }),
        "open_router" => Some(PropagationSpec {
            source: "open_router".into(),
            app: None,
            name: "OpenRouter inference".into(),
            description: "Route LLM calls through OpenRouter — Claude, GPT, Gemini, Mistral, more."
                .into(),
        }),
        "gemini" => Some(PropagationSpec {
            source: "gemini".into(),
            app: None,
            name: "Gemini Live audio".into(),
            description:
                "Bidirectional audio sessions via the Gemini Live WebSocket. Lets the agent talk \
                 and listen in real time; same system prompt and bash tool as the OpenRouter path."
                    .into(),
        }),
        "claude_code" => Some(PropagationSpec {
            source: "claude_code".into(),
            app: None,
            name: "Claude Code sub-agent".into(),
            description:
                "Delegate coding tasks to Anthropic's Claude Code CLI installed on this machine."
                    .into(),
        }),
        "codex" => Some(PropagationSpec {
            source: "codex".into(),
            app: None,
            name: "Codex sub-agent".into(),
            description:
                "Delegate work to OpenAI's Codex CLI installed on this machine.".into(),
        }),
        "google_workspace" => Some(PropagationSpec {
            source: "google_workspace".into(),
            app: None,
            name: "Google Workspace operations".into(),
            description:
                "Drive, Gmail, Calendar, Sheets, Docs, Chat, Admin via the gws CLI.".into(),
        }),
        "github" | "meta" => None, // Coming-soon; skills land when OAuth does.
        _ => None,
    }
}

/// Add (or update) the connection-driven skill for a service. Called
/// from `connections::connections_create`. Errors are logged but don't
/// fail the connect — the skill is auxiliary metadata.
pub async fn upsert_from_connection(service: &str) {
    let Some(spec) = propagation_spec_for_service(service) else {
        return;
    };
    let mut all = match read_all().await {
        Ok(a) => a,
        Err(e) => {
            log::warn!("[skills] read on upsert failed: {e}");
            return;
        }
    };

    // Idempotent: replace any existing entry with the same (source, app).
    all.retain(|s| !(s.source == spec.source && s.app == spec.app));

    all.push(Skill {
        id: new_id(),
        name: spec.name,
        description: spec.description,
        source: spec.source.clone(),
        app: spec.app,
        scope: SkillScope::User,
        workspace_id: None,
        package_name: None,
        skill_md_path: None,
        created_at: now_ms(),
    });

    if let Err(e) = write_all(&all).await {
        log::warn!("[skills] write on upsert failed: {e}");
    }
}

/// Remove every skill tied to the given source. Called from
/// `connections::connections_delete` so a disconnect tidies up.
pub async fn remove_for_source(service: &str) {
    let mut all = match read_all().await {
        Ok(a) => a,
        Err(e) => {
            log::warn!("[skills] read on remove failed: {e}");
            return;
        }
    };
    let before = all.len();
    all.retain(|s| s.source != service);
    if all.len() == before {
        return;
    }
    if let Err(e) = write_all(&all).await {
        log::warn!("[skills] write on remove failed: {e}");
    }
}

// ── Tauri commands ──────────────────────────────────────────────────

#[tauri::command]
pub async fn skills_list() -> Result<Vec<Skill>, String> {
    let mut all = read_all().await?;
    all.sort_by_key(|s| std::cmp::Reverse(s.created_at));
    Ok(all)
}

#[derive(Deserialize)]
pub struct SkillScopeUpdate {
    pub id: String,
    pub scope: SkillScope,
    #[serde(default)]
    pub workspace_id: Option<String>,
    #[serde(default)]
    pub package_name: Option<String>,
}

#[tauri::command]
pub async fn skills_set_scope(req: SkillScopeUpdate) -> Result<(), String> {
    let mut all = read_all().await?;
    let s = all
        .iter_mut()
        .find(|s| s.id == req.id)
        .ok_or_else(|| format!("no skill with id {}", req.id))?;
    s.scope = req.scope;
    s.workspace_id = match req.scope {
        SkillScope::Workspace | SkillScope::Package => req.workspace_id,
        SkillScope::User => None,
    };
    s.package_name = match req.scope {
        SkillScope::Package => req.package_name,
        _ => None,
    };
    write_all(&all).await
}

#[tauri::command]
pub async fn skills_delete(id: String) -> Result<(), String> {
    let mut all = read_all().await?;
    let before = all.len();
    all.retain(|s| s.id != id);
    if all.len() == before {
        return Err(format!("no skill with id {id}"));
    }
    write_all(&all).await
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tempdir_str() -> String {
        let mut p = std::env::temp_dir();
        p.push(format!(
            "oql-desktop-skills-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        p.to_string_lossy().into_owned()
    }

    #[tokio::test(flavor = "current_thread")]
    async fn upsert_and_list_roundtrip() {
        let tmp = tempdir_str();
        std::env::set_var("OQL_DESKTOP_HOME", &tmp);
        std::fs::create_dir_all(&tmp).unwrap();

        upsert_from_connection("composio").await;
        let listed = skills_list().await.unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].source, "composio");
        assert!(matches!(listed[0].scope, SkillScope::User));

        // Idempotent: upsert again replaces, doesn't dupe.
        upsert_from_connection("composio").await;
        assert_eq!(skills_list().await.unwrap().len(), 1);

        std::env::remove_var("OQL_DESKTOP_HOME");
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn remove_for_source_cleans_up() {
        let tmp = tempdir_str();
        std::env::set_var("OQL_DESKTOP_HOME", &tmp);
        std::fs::create_dir_all(&tmp).unwrap();

        upsert_from_connection("composio").await;
        upsert_from_connection("doppler").await;
        assert_eq!(skills_list().await.unwrap().len(), 2);

        remove_for_source("composio").await;
        let listed = skills_list().await.unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].source, "doppler");

        std::env::remove_var("OQL_DESKTOP_HOME");
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn set_scope_workspace_and_package() {
        let tmp = tempdir_str();
        std::env::set_var("OQL_DESKTOP_HOME", &tmp);
        std::fs::create_dir_all(&tmp).unwrap();

        upsert_from_connection("composio").await;
        let id = skills_list().await.unwrap()[0].id.clone();

        skills_set_scope(SkillScopeUpdate {
            id: id.clone(),
            scope: SkillScope::Workspace,
            workspace_id: Some("ws_foo".into()),
            package_name: None,
        })
        .await
        .unwrap();
        let s = &skills_list().await.unwrap()[0];
        assert!(matches!(s.scope, SkillScope::Workspace));
        assert_eq!(s.workspace_id.as_deref(), Some("ws_foo"));

        // Switching back to user clears the targets.
        skills_set_scope(SkillScopeUpdate {
            id,
            scope: SkillScope::User,
            workspace_id: Some("ws_foo".into()),
            package_name: None,
        })
        .await
        .unwrap();
        let s = &skills_list().await.unwrap()[0];
        assert!(matches!(s.scope, SkillScope::User));
        assert!(s.workspace_id.is_none());

        std::env::remove_var("OQL_DESKTOP_HOME");
        let _ = std::fs::remove_dir_all(&tmp);
    }
}
