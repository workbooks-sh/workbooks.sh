// org_kv — thin layer on top of `oql-core` for storing the
// desktop's config files as org documents instead of JSON.
//
// Each config is one .org file. Top-level headings represent entries;
// each entry's structured fields live in its `:PROPERTIES:` drawer.
// File header carries a `#+SCHEMA:` keyword so we can fail loudly if
// the wrong file gets opened with the wrong reader.
//
// Example (bookmarks.org):
//
//     #+SCHEMA: bookmarks.v1
//
//     * Bug tracker
//     :PROPERTIES:
//     :id: bm_abc
//     :path: /Users/me/proj/issues.org
//     :command_slot: 1
//     :created_at: 1716661234000
//     :END:
//
//     * Daily notes
//     :PROPERTIES:
//     :id: bm_def
//     :path: /Users/me/notes/today.org
//     :END:
//
// Why this and not JSON: the rest of the system (OQL agents, plans,
// skills) already speaks org. An agent editing its bookmarks looks
// identical to the agent editing a task graph — it's the same
// substrate end to end, no `JSON.parse`/`stringify` ceremony, and
// agents can co-author the file without a serializer ping-pong.
//
// We rewrite the whole file on every mutation. The on-disk content
// is generated from `Vec<OrgEntry>`, so any user-added free-form
// content outside our known heading shape is NOT preserved. That's
// fine for config files we own — for plan files / agent definitions
// the agent edits in place via `oql-core::Document::set_property`,
// which IS edit-preserving.

use std::collections::BTreeMap;
use std::path::Path;

use orgize::ast::Headline;
use tokio::fs;
use oql_core::Document;

/// One entry in an org-kv file. Properties are ordered for stable
/// on-disk output.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct OrgEntry {
    pub title: String,
    pub properties: BTreeMap<String, String>,
}

impl OrgEntry {
    pub fn new(title: impl Into<String>) -> Self {
        Self {
            title: title.into(),
            properties: BTreeMap::new(),
        }
    }

    pub fn with(mut self, key: impl Into<String>, value: impl Into<String>) -> Self {
        self.properties.insert(key.into(), value.into());
        self
    }

    pub fn get(&self, key: &str) -> Option<&str> {
        // Case-insensitive lookup — org property keys uppercase on
        // disk, but callers think in lowercase.
        for (k, v) in &self.properties {
            if k.eq_ignore_ascii_case(key) {
                return Some(v.as_str());
            }
        }
        None
    }

    pub fn get_i64(&self, key: &str) -> Option<i64> {
        self.get(key).and_then(|v| v.parse().ok())
    }

    pub fn get_u8(&self, key: &str) -> Option<u8> {
        self.get(key).and_then(|v| v.parse().ok())
    }
}

/// Read every top-level heading from an org file as an OrgEntry.
/// Returns an empty vec if the file doesn't exist (first run).
/// Errors if the schema marker doesn't match.
pub async fn read_entries(
    path: &Path,
    expected_schema: &str,
) -> Result<Vec<OrgEntry>, String> {
    let src = match fs::read_to_string(path).await {
        Ok(s) => s,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(vec![]),
        Err(e) => return Err(format!("read {}: {e}", path.display())),
    };

    let actual_schema = parse_schema(&src);
    if !actual_schema.is_empty() && actual_schema != expected_schema {
        return Err(format!(
            "schema mismatch in {}: expected `{expected_schema}`, got `{actual_schema}`",
            path.display()
        ));
    }

    let doc = Document::parse(&src);
    let mut entries: Vec<OrgEntry> = Vec::new();
    for hl in doc.headlines() {
        // Only top-level (level 1) entries are kv-records. Nested
        // sub-headings are out of scope for config files.
        if hl.level() != 1 {
            continue;
        }
        let title = headline_title_text(&hl);
        let mut props = BTreeMap::new();
        if let Some(p) = hl.properties() {
            for (k, v) in p.iter() {
                props.insert(k.to_string().to_uppercase(), v.to_string());
            }
        }
        entries.push(OrgEntry { title, properties: props });
    }
    Ok(entries)
}

/// Rewrite an org-kv file with the given entries. Atomic via
/// write-to-tmp + rename so a crash mid-write can't leave a partial
/// file.
pub async fn write_entries(
    path: &Path,
    schema: &str,
    entries: &[OrgEntry],
) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .await
            .map_err(|e| format!("mkdir {}: {e}", parent.display()))?;
    }
    let body = render(schema, entries);
    let tmp = path.with_extension(format!(
        "{}.tmp",
        path.extension()
            .and_then(|s| s.to_str())
            .unwrap_or("org")
    ));
    fs::write(&tmp, &body)
        .await
        .map_err(|e| format!("write tmp {}: {e}", tmp.display()))?;
    fs::rename(&tmp, path)
        .await
        .map_err(|e| format!("rename {} -> {}: {e}", tmp.display(), path.display()))?;
    Ok(())
}

fn render(schema: &str, entries: &[OrgEntry]) -> String {
    let mut out = String::new();
    out.push_str("#+SCHEMA: ");
    out.push_str(schema);
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

fn parse_schema(src: &str) -> String {
    for line in src.lines().take(20) {
        let trimmed = line.trim();
        if let Some(rest) = trimmed.strip_prefix("#+SCHEMA:") {
            return rest.trim().to_string();
        }
        if trimmed.starts_with("* ") {
            break; // first heading — done with the header block
        }
    }
    String::new()
}

/// Plain-text title of a headline (with no TODO keyword / priority /
/// tags). orgize exposes title segments piecewise; the simplest
/// extract that handles inline markup is to walk children and grab
/// text from the title row.
fn headline_title_text(hl: &Headline) -> String {
    hl.title_raw().trim().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn round_trip_two_entries() {
        let dir = tempdir();
        let path = dir.join("bookmarks.org");
        let entries = vec![
            OrgEntry::new("First")
                .with("ID", "x1")
                .with("PATH", "/tmp/a.org")
                .with("CREATED_AT", "1000"),
            OrgEntry::new("Second")
                .with("ID", "x2")
                .with("PATH", "/tmp/b.org")
                .with("COMMAND_SLOT", "3")
                .with("CREATED_AT", "2000"),
        ];
        write_entries(&path, "bookmarks.v1", &entries).await.unwrap();
        let back = read_entries(&path, "bookmarks.v1").await.unwrap();
        assert_eq!(back.len(), 2);
        assert_eq!(back[0].title, "First");
        assert_eq!(back[0].get("PATH"), Some("/tmp/a.org"));
        assert_eq!(back[1].title, "Second");
        assert_eq!(back[1].get_u8("COMMAND_SLOT"), Some(3));
        assert_eq!(back[1].get_i64("CREATED_AT"), Some(2000));
    }

    #[tokio::test]
    async fn missing_file_yields_empty() {
        let dir = tempdir();
        let path = dir.join("nope.org");
        let back = read_entries(&path, "bookmarks.v1").await.unwrap();
        assert!(back.is_empty());
    }

    #[tokio::test]
    async fn schema_mismatch_errors() {
        let dir = tempdir();
        let path = dir.join("bookmarks.org");
        tokio::fs::write(&path, "#+SCHEMA: something.else.v1\n\n* A\n")
            .await
            .unwrap();
        let err = read_entries(&path, "bookmarks.v1").await.unwrap_err();
        assert!(err.contains("schema mismatch"), "got: {err}");
    }

    fn tempdir() -> std::path::PathBuf {
        use std::time::{SystemTime, UNIX_EPOCH};
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let p = std::env::temp_dir().join(format!("wb-org-kv-{nanos}"));
        std::fs::create_dir_all(&p).unwrap();
        p
    }
}
