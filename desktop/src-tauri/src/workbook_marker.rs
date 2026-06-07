// wb-i38o.37 — workbook content-marker detection.
//
// Replaces the previous "every .html is a workbook" heuristic in
// `tabs.rs`. Per `packages/workbooks/FORMAT.md`, a workbook is any
// HTML file that contains an inline `<script id="workbook-spec"
// type="application/json">…</script>` block. Filename and extension
// are irrelevant to the host contract — workbooks survive renames
// and `foo (1).html` collisions because they identify themselves
// via the inline script id.
//
// This module is the single place that decides "is this a
// workbook?" — both `TabKind::detect` and the future package grid
// view (wb-i38o.38) call into here. Keep the scan cheap: bounded
// head read, no persistent cache, fresh result every call.
//
// Tolerance:
//   * Double or single quoted `id` value.
//   * Case-insensitive on the attribute name (HTML allows `ID=`).
//   * Whitespace tolerated between `id`, `=`, and the value.
//   * Read errors and non-UTF-8 → false (fail closed, not loud).
//
// Bounded by HEAD_BYTES because the spec puts manifest script
// blocks at the top of the document. A pathological workbook that
// stashes its marker past 16 KB is not portable per FORMAT.md and
// is not our problem to identify.

use std::path::Path;

use tokio::io::AsyncReadExt;

/// Maximum bytes scanned from the head of a candidate file. The
/// canonical FORMAT.md layout places the `workbook-spec` script in
/// the document `<head>`, which sits well under 16 KB even with a
/// large baked source bundle (the bundle ships in a separate later
/// script block).
const HEAD_BYTES: usize = 16 * 1024;

/// Returns `true` when `path` opens to an HTML document containing
/// the `<script id="workbook-spec">` marker within the first
/// `HEAD_BYTES`. Returns `false` on read errors or non-UTF-8.
pub async fn scan(path: &Path) -> bool {
    let mut file = match tokio::fs::File::open(path).await {
        Ok(f) => f,
        Err(_) => return false,
    };
    let mut buf = vec![0u8; HEAD_BYTES];
    let n = match file.read(&mut buf).await {
        Ok(n) => n,
        Err(_) => return false,
    };
    let head = match std::str::from_utf8(&buf[..n]) {
        Ok(s) => s,
        Err(_) => return false,
    };
    contains_marker(head)
}

fn contains_marker(head: &str) -> bool {
    // Normalize once: lowercased plus internal whitespace collapse
    // around `id=`. Allocating one String here is fine — `head` is
    // bounded by HEAD_BYTES.
    let lower = head.to_ascii_lowercase();
    // Cheap pre-filter: bail when the slug is absent entirely.
    if !lower.contains("workbook-spec") {
        return false;
    }
    // Match the canonical double-quote form first (what the CLI emits).
    if lower.contains("id=\"workbook-spec\"") || lower.contains("id='workbook-spec'") {
        return true;
    }
    // Fallback — tolerate whitespace around `=` (HTML legal).
    contains_spaced_attr(&lower)
}

fn contains_spaced_attr(lower: &str) -> bool {
    let bytes = lower.as_bytes();
    let mut i = 0;
    while i + 1 < bytes.len() {
        if bytes[i] == b'i' && bytes[i + 1] == b'd' {
            let mut j = i + 2;
            while j < bytes.len() && (bytes[j] == b' ' || bytes[j] == b'\t') {
                j += 1;
            }
            if j < bytes.len() && bytes[j] == b'=' {
                j += 1;
                while j < bytes.len() && (bytes[j] == b' ' || bytes[j] == b'\t') {
                    j += 1;
                }
                if j < bytes.len() && (bytes[j] == b'"' || bytes[j] == b'\'') {
                    j += 1;
                    let needle = b"workbook-spec";
                    if bytes[j..].starts_with(needle) {
                        return true;
                    }
                }
            }
        }
        i += 1;
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_canonical_double_quoted() {
        let html = r#"<!doctype html><html><head><script id="workbook-spec" type="application/json">{}</script></head></html>"#;
        assert!(contains_marker(html));
    }

    #[test]
    fn matches_single_quoted() {
        let html = "<script id='workbook-spec' type='application/json'>{}</script>";
        assert!(contains_marker(html));
    }

    #[test]
    fn matches_uppercase_id() {
        let html = r#"<script ID="workbook-spec">{}</script>"#;
        assert!(contains_marker(html));
    }

    #[test]
    fn matches_with_whitespace_around_equals() {
        let html = r#"<script id = "workbook-spec" type="application/json">{}</script>"#;
        assert!(contains_marker(html));
    }

    #[test]
    fn rejects_plain_html_without_marker() {
        let html = "<!doctype html><html><body><h1>hello</h1></body></html>";
        assert!(!contains_marker(html));
    }

    #[test]
    fn rejects_when_slug_appears_outside_an_id_attr() {
        // Pre-filter would pass but the structured check must reject.
        let html = r#"<p>The string workbook-spec is in the body but no id attribute references it.</p>"#;
        assert!(!contains_marker(html));
    }

    #[test]
    fn rejects_wrong_id_value() {
        let html = r#"<script id="not-a-workbook">{}</script>"#;
        assert!(!contains_marker(html));
    }

    use std::sync::atomic::{AtomicU64, Ordering};

    static COUNTER: AtomicU64 = AtomicU64::new(0);

    fn temp_html_path(stem: &str) -> std::path::PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!(
            "oql-marker-test-{}-{}-{}.html",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::SeqCst),
            stem
        ));
        p
    }

    #[tokio::test(flavor = "current_thread")]
    async fn scan_returns_false_for_missing_file() {
        let bogus = std::path::PathBuf::from("/this/path/should/not/exist.html");
        assert!(!scan(&bogus).await);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn scan_reads_real_file() {
        let path = temp_html_path("wb");
        tokio::fs::write(
            &path,
            r#"<!doctype html><script id="workbook-spec" type="application/json">{"slug":"x"}</script>"#,
        )
        .await
        .unwrap();
        assert!(scan(&path).await);
        let _ = tokio::fs::remove_file(&path).await;
    }

    #[tokio::test(flavor = "current_thread")]
    async fn scan_ignores_marker_past_head_bytes() {
        let path = temp_html_path("late");
        // Pad past HEAD_BYTES so the marker is unreachable in one read.
        let padding = "<!-- pad -->".repeat(HEAD_BYTES);
        let content =
            format!(r#"{padding}<script id="workbook-spec">{{}}</script>"#);
        tokio::fs::write(&path, content).await.unwrap();
        assert!(!scan(&path).await);
        let _ = tokio::fs::remove_file(&path).await;
    }
}
