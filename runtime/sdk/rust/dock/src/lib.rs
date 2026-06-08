//! # Dock SDK (Rust)
//!
//! Ergonomic, cap-scoped bindings for `workbooks:engine` toolkit authors. The
//! Dock's raw WIT imports are stringly (`func(string) -> string`); this crate
//! turns them into typed, fallible, idiomatic calls and kills the two pains in
//! hand-written components: parsing Dock JSON by hand, and building the `run`
//! return string with `format!` + quote-escaping hacks.
//!
//! Two layers:
//! - **Pure core** (this module): [`out`], [`rows`], [`page`], [`Session`],
//!   [`Page`], [`DockError`], [`Result`]. No imports, no `wasm32` requirement —
//!   compiles and unit-tests on the host. This is the marshalling win.
//! - **Cap wrappers** (`dock::llm::ask`, `dock::vfs::query`, …): materialized by
//!   the [`bind!`] macro over the author's wit-bindgen-generated `bindings`
//!   module, gated by Cargo feature so only granted caps are linked. See the
//!   crate README / DOCK-SDK.org for the cap-scoping rule.
//!
//! ```ignore
//! mod bindings;            // wit-bindgen output for your WIT subset world
//! dock::bind!(bindings);   // emits dock::llm / dock::vfs / … for enabled features
//!
//! impl bindings::Guest for Me {
//!     fn run(input: String) -> String {
//!         let reply = dock::llm::ask(format!("In 5 words: {input}")).unwrap();
//!         dock::out(serde_json::json!({ "asked": input, "llm": reply }))
//!     }
//! }
//! ```

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};

/// A Dock call that failed host-side. The host returns errors as a JSON string
/// `{"error": "..."}`; the SDK lifts that into `Err` instead of letting a
/// corrupt value flow downstream.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DockError(pub String);

impl core::fmt::Display for DockError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        write!(f, "dock error: {}", self.0)
    }
}

impl std::error::Error for DockError {}

/// Result of a fallible Dock call.
pub type Result<T> = core::result::Result<T, DockError>;

/// The read-only identity record from `session-info` (always granted).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Session {
    #[serde(default)]
    pub id: Option<String>,
    #[serde(default)]
    pub tenant: Option<String>,
    /// Any additional fields the host includes, preserved verbatim.
    #[serde(flatten, default)]
    pub extra: serde_json::Map<String, serde_json::Value>,
}

/// A fetched+extracted page from `browse-fetch` (Route B: the host owns egress).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Page {
    #[serde(default)]
    pub url: Option<String>,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub text: Option<String>,
    #[serde(flatten, default)]
    pub extra: serde_json::Map<String, serde_json::Value>,
}

/// Build the `run` return string from any serializable value — the clean
/// replacement for hand-rolled `format!("{{...}}")` + quote escaping.
pub fn out(value: impl Serialize) -> String {
    // Infallible in practice for the shapes a component returns; fall back to a
    // structured error string rather than panicking inside the sandbox.
    serde_json::to_string(&value)
        .unwrap_or_else(|e| format!("{{\"error\":\"serialize: {e}\"}}"))
}

/// Parse a Dock JSON string into rows of `T` (e.g. the result of `vfs-query`).
/// A host `{"error": ...}` envelope becomes `Err`.
pub fn rows<T: DeserializeOwned>(json: &str) -> Result<Vec<T>> {
    check_error(json)?;
    serde_json::from_str(json).map_err(|e| DockError(format!("decode rows: {e}")))
}

/// Parse a Dock JSON string into a [`Page`] (the result of `browse-fetch`).
pub fn page(json: &str) -> Result<Page> {
    check_error(json)?;
    serde_json::from_str(json).map_err(|e| DockError(format!("decode page: {e}")))
}

/// Parse the `session-info` record.
pub fn session_from(json: &str) -> Result<Session> {
    check_error(json)?;
    serde_json::from_str(json).map_err(|e| DockError(format!("decode session: {e}")))
}

/// If `json` is a host error envelope (`{"error": "..."}`), return it as `Err`.
/// Otherwise `Ok(())`. Public so hand-declared imports can reuse the convention.
pub fn check_error(json: &str) -> Result<()> {
    if let Ok(serde_json::Value::Object(m)) = serde_json::from_str::<serde_json::Value>(json) {
        if let Some(serde_json::Value::String(e)) = m.get("error") {
            // Heuristic: a lone {"error": "..."} object is the host envelope.
            if m.len() == 1 {
                return Err(DockError(e.clone()));
            }
        }
    }
    Ok(())
}

/// Emit the ergonomic, feature-gated cap wrappers (`dock::llm`, `dock::vfs`,
/// `dock::browse`, `dock::command`) over the author's wit-bindgen `bindings`
/// module. Call once, passing the path to the generated module. Each wrapper is
/// `#[cfg(feature = ...)]`-gated, so only the caps you enabled (== the caps your
/// WIT subset declares == the caps your profile grants) are materialized.
///
/// Staged caps (`parallel`, `frames`) are intentionally NOT emitted here; their
/// host side is wb-rhs.9. Enabling those features trips the `compile_error!`
/// guards below instead.
#[macro_export]
macro_rules! bind {
    ($bindings:path) => {
        #[allow(unused_imports)]
        mod dock_caps {
            use super::$bindings as b;

            #[cfg(feature = "llm")]
            pub mod llm {
                use super::b;
                /// Ask the model; the host holds the key, the component never sees it.
                pub fn ask(prompt: impl AsRef<str>) -> $crate::Result<String> {
                    let r = b::llm_complete(prompt.as_ref());
                    $crate::check_error(&r)?;
                    Ok(r)
                }
            }

            #[cfg(feature = "vfs")]
            pub mod vfs {
                use super::b;
                /// Run SQL against the Instance VFS; decode rows into `T`.
                pub fn query<T: serde::de::DeserializeOwned>(sql: impl AsRef<str>) -> $crate::Result<Vec<T>> {
                    $crate::rows(&b::vfs_query(sql.as_ref()))
                }
                /// Raw JSON form, if you want to inspect before decoding.
                pub fn query_raw(sql: impl AsRef<str>) -> $crate::Result<String> {
                    let r = b::vfs_query(sql.as_ref());
                    $crate::check_error(&r)?;
                    Ok(r)
                }
            }

            #[cfg(feature = "browse")]
            pub mod browse {
                use super::b;
                /// Fetch+extract a URL through the host Browse cap (never holds a socket).
                pub fn fetch(url: impl AsRef<str>) -> $crate::Result<$crate::Page> {
                    $crate::page(&b::browse_fetch(url.as_ref()))
                }
            }

            #[cfg(feature = "commands")]
            pub mod command {
                use super::b;
                /// Invoke a registered command (argv + stdin → stdout).
                pub fn run(name: impl AsRef<str>, input: impl AsRef<str>, args: &[&str]) -> $crate::Result<String> {
                    let argv: Vec<String> = args.iter().map(|s| s.to_string()).collect();
                    let r = b::run_command(name.as_ref(), input.as_ref(), &argv);
                    $crate::check_error(&r)?;
                    Ok(r)
                }
            }
        }

        // Re-export so authors write `dock::llm::ask(..)` etc.
        #[allow(unused_imports)]
        pub use dock_caps::*;
    };
}

// ── Staged-cap guards ──────────────────────────────────────────────────────
// The surface is documented in DOCK-SDK.org; the host bindings land in wb-rhs.9.
#[cfg(feature = "parallel")]
compile_error!(
    "dock feature `parallel` (BEAM concurrency fan-out, dock::parallel::map) is \
     not yet available — host cap wb-rhs.9. Remove the feature to build."
);
#[cfg(feature = "frames")]
compile_error!(
    "dock feature `frames` (shared-frame arena, dock::frames) is not yet \
     available — host cap wb-rhs.9. Remove the feature to build."
);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn out_builds_clean_json() {
        let s = out(serde_json::json!({ "asked": "hi \"there\"", "n": 3 }));
        // Quotes are escaped correctly — no lossy replace('"',"'") hack.
        assert_eq!(s, r#"{"asked":"hi \"there\"","n":3}"#);
    }

    #[test]
    fn rows_decodes() {
        #[derive(serde::Deserialize, PartialEq, Debug)]
        struct R { n: i64 }
        let v: Vec<R> = rows(r#"[{"n":1},{"n":2}]"#).unwrap();
        assert_eq!(v, vec![R { n: 1 }, R { n: 2 }]);
    }

    #[test]
    fn error_envelope_lifts_to_err() {
        let e = rows::<serde_json::Value>(r#"{"error":"boom"}"#).unwrap_err();
        assert_eq!(e, DockError("boom".into()));
    }

    #[test]
    fn page_with_error_envelope_is_err() {
        assert!(page(r#"{"error":"nope"}"#).is_err());
    }

    #[test]
    fn page_decodes_and_keeps_extra() {
        let p = page(r#"{"url":"u","title":"t","text":"x","lang":"en"}"#).unwrap();
        assert_eq!(p.url.as_deref(), Some("u"));
        assert_eq!(p.extra.get("lang").unwrap(), "en");
    }
}
