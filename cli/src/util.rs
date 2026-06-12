//! Small shared utilities: the lenient Org keyword parser (deployment.org /
//! publish.org), ISO-8601 UTC time, percent-encoding for query strings, and the
//! per-OS app-data dir (the same `sh.workbooks` root the runtime/desktop use).

use std::collections::BTreeMap;
use std::path::PathBuf;

/// Lenient Org config reader: collect `#+KEY: value` keywords and `:KEY: value`
/// property-drawer lines into one map (keys upper-cased).
pub fn org_keywords(src: &str) -> BTreeMap<String, String> {
    let mut m = BTreeMap::new();
    for line in src.lines() {
        let l = line.trim();
        let rest = l.strip_prefix("#+").or_else(|| l.strip_prefix(':'));
        if let Some((k, v)) = rest.and_then(|r| r.split_once(':')) {
            let key = k.trim().trim_matches(':').to_uppercase();
            let val = v.trim().to_string();
            if !key.is_empty() && !val.is_empty() {
                m.insert(key, val);
            }
        }
    }
    m
}

/// Unix seconds now. Works on native and wasm32-wasip1 (WASI clocks).
pub fn unix_now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// ISO-8601 UTC timestamp (e.g. `2026-06-09T18:21:07Z`), no chrono dependency.
/// Civil-from-days per Howard Hinnant's algorithm.
pub fn iso_now() -> String {
    let secs = unix_now() as i64;
    let days = secs.div_euclid(86_400);
    let sod = secs.rem_euclid(86_400);
    let (h, mi, s) = (sod / 3600, (sod % 3600) / 60, sod % 60);

    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };

    format!("{y:04}-{m:02}-{d:02}T{h:02}:{mi:02}:{s:02}Z")
}

/// Percent-encode a query-string value (RFC 3986 unreserved kept).
pub fn urlenc(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// The per-OS `sh.workbooks` app-data root (same family as the runtime's
/// discovery dir): macOS `~/Library/Application Support/sh.workbooks`,
/// elsewhere `~/.local/share/sh.workbooks`.
pub fn app_dir() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_default();
    if cfg!(target_os = "macos") {
        [&home, "Library", "Application Support", "sh.workbooks"].iter().collect()
    } else {
        [&home, ".local", "share", "sh.workbooks"].iter().collect()
    }
}

/// Env lookup with the canonical prefix first: `WBX_<key>`, falling back to
/// the legacy `WB_<key>`. Docs say WBX_*; both work.
pub fn env_var(key: &str) -> Option<String> {
    std::env::var(format!("WBX_{key}"))
        .or_else(|_| std::env::var(format!("WB_{key}")))
        .ok()
}
