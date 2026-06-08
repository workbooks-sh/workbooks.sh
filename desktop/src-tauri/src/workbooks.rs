// Workbook-spec extraction + memory-source resolution. A workbook is a single
// .html whose embedded `<script id="workbook-spec">…</script>` holds the JSON
// spec; this is the native port of `workbook.ex`'s reader. The actual semantic
// indexing of a memory source stays in the runtime — here we only canonicalise
// + validate the path the runtime will index.

use serde::Serialize;
use serde_json::Value;
use std::sync::OnceLock;

/// Compiled once: matches `<script id="workbook-spec" …>…</script>` across
/// newlines (the spec is pretty-printed JSON).
fn spec_re() -> &'static regex::Regex {
    static RE: OnceLock<regex::Regex> = OnceLock::new();
    RE.get_or_init(|| {
        regex::Regex::new(r#"(?s)<script id="workbook-spec"[^>]*>(.*?)</script>"#).unwrap()
    })
}

/// Extract the JSON spec embedded in a workbook .html. None when the file is
/// missing the marker or the JSON doesn't parse.
pub fn read_spec(path: &str) -> Option<Value> {
    let body = std::fs::read_to_string(path).ok()?;
    let caps = spec_re().captures(&body)?;
    let json = caps.get(1)?.as_str().trim();
    serde_json::from_str(json).ok()
}

#[tauri::command]
pub fn workbook_spec_read(path: String) -> Option<Value> {
    read_spec(&path)
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LoadResolution {
    pub canonical_path: String,
}

/// Canonicalise the .html path the runtime will index as a memory source.
/// Rejects non-html extensions; indexing itself is a runtime concern.
#[tauri::command]
pub fn memory_source_resolve(html_path: String) -> Result<LoadResolution, String> {
    let ext = std::path::Path::new(&html_path)
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| e.to_lowercase())
        .unwrap_or_default();
    if ext != "html" && ext != "htm" {
        return Err(format!("not a workbook (.html): {html_path}"));
    }
    let canon = std::fs::canonicalize(&html_path).map_err(|e| format!("{html_path}: {e}"))?;
    Ok(LoadResolution {
        canonical_path: canon.to_string_lossy().to_string(),
    })
}
