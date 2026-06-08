// Minimal org-property reader/writer for the `<name>.org` descriptors the
// package + agent-settings layers persist. We DON'T pull in a full org parser
// here — these files are flat `:KEY: value` property drawers the desktop owns,
// so a line-oriented get/set is enough (and matches `workbook.ex`'s convention).
//
//   :folders: a, b, c        → comma-joined list
//   :icon: 📦
//   :view-mode: source
//
// Unknown lines (headlines, body text) are preserved on set.

/// Read the first `:key:` property value (trimmed), case-insensitive on the key.
pub fn get(body: &str, key: &str) -> Option<String> {
    let needle = format!(":{}:", key.to_lowercase());
    for line in body.lines() {
        let t = line.trim();
        let lower = t.to_lowercase();
        if let Some(rest) = lower.strip_prefix(&needle) {
            // Re-slice the ORIGINAL line to preserve value casing.
            let val = &t[needle.len()..t.len()];
            let _ = rest; // lower used only for the prefix test
            return Some(val.trim().to_string());
        }
    }
    None
}

/// Read a comma-separated list property (empty vec when absent/blank).
pub fn get_list(body: &str, key: &str) -> Vec<String> {
    match get(body, key) {
        Some(v) if !v.trim().is_empty() => v
            .split(',')
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect(),
        _ => Vec::new(),
    }
}

/// Set (or insert) a `:key:` property, returning the new body. Replaces the
/// first existing occurrence; otherwise appends a fresh property line.
pub fn set(body: &str, key: &str, value: &str) -> String {
    let needle = format!(":{}:", key.to_lowercase());
    let mut out: Vec<String> = Vec::new();
    let mut replaced = false;
    for line in body.lines() {
        if !replaced && line.trim().to_lowercase().starts_with(&needle) {
            out.push(format!(":{}: {}", key.to_lowercase(), value));
            replaced = true;
        } else {
            out.push(line.to_string());
        }
    }
    if !replaced {
        out.push(format!(":{}: {}", key.to_lowercase(), value));
    }
    let mut joined = out.join("\n");
    if !joined.ends_with('\n') {
        joined.push('\n');
    }
    joined
}

/// Set a comma-joined list property.
pub fn set_list(body: &str, key: &str, items: &[String]) -> String {
    set(body, key, &items.join(", "))
}

/// Remove a `:key:` property entirely (used to clear optional config).
pub fn remove(body: &str, key: &str) -> String {
    let needle = format!(":{}:", key.to_lowercase());
    let kept: Vec<&str> = body
        .lines()
        .filter(|l| !l.trim().to_lowercase().starts_with(&needle))
        .collect();
    let mut joined = kept.join("\n");
    if !joined.is_empty() && !joined.ends_with('\n') {
        joined.push('\n');
    }
    joined
}
