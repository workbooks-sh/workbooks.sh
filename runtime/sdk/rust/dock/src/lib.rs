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
//!   crate README / DOCK-SDK.md for the cap-scoping rule.
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

/// Parse the JSON array a `run-command-many` (parallel) Dock call returns into
/// per-worker results: each element is `{"ok": stdout}` or `{"error": reason}`,
/// in input order. The outer `Result` is the call itself; each inner `Result` is
/// one worker.
pub fn parse_many(json: &str) -> Result<Vec<Result<String>>> {
    check_error(json)?;

    let arr: Vec<serde_json::Value> =
        serde_json::from_str(json).map_err(|e| DockError(format!("decode many: {e}")))?;

    Ok(arr
        .into_iter()
        .map(|v| match v.get("ok") {
            Some(serde_json::Value::String(s)) => Ok(s.clone()),
            _ => Err(DockError(
                v.get("error").and_then(|e| e.as_str()).unwrap_or("unknown").to_string(),
            )),
        })
        .collect())
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

/// Emit the ergonomic cap wrappers (`dock::llm`, `dock::vfs`, `dock::browse`,
/// `dock::command`, `dock::parallel`) over the author's wit-bindgen `bindings`
/// module, for an EXPLICIT cap list that must match the component's WIT world:
///
/// ```ignore
/// mod bindings;                     // cargo-component / wit-bindgen output
/// dock::bind!(bindings, command, llm);   // only the caps your world imports
/// ```
///
/// Cap-scoping is the LIST (and the WIT world), NOT Cargo features — a feature on
/// the `dock` dependency is invisible to this macro (it expands in the caller's
/// crate, whose features differ), which silently emitted nothing. The list is the
/// fix. A cap with no arm below (e.g. `frames`, not yet built) is a compile error.
#[macro_export]
macro_rules! bind {
    ($bindings:ident $(, $cap:ident)* $(,)?) => {
        #[allow(unused_imports)]
        mod dock_caps {
            use super::$bindings as b;
            $( $crate::__dock_cap!($cap); )*
        }
        #[allow(unused_imports)]
        pub use dock_caps::*;
    };
}

/// Per-cap wrapper emitter (one arm per Dock capability). Invoked inside
/// `dock_caps`, so each `pub mod <cap>` sees `super::b` (the bindings alias).
#[macro_export]
#[doc(hidden)]
macro_rules! __dock_cap {
    (llm) => {
        pub mod llm {
            use super::b;
            /// Ask the model; the host holds the key, the component never sees it.
            pub fn ask(prompt: impl AsRef<str>) -> $crate::Result<String> {
                let r = b::llm_complete(prompt.as_ref());
                $crate::check_error(&r)?;
                Ok(r)
            }
        }
    };
    (vfs) => {
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
    };
    (browse) => {
        pub mod browse {
            use super::b;
            /// Fetch+extract a URL through the host Browse cap (never holds a socket).
            pub fn fetch(url: impl AsRef<str>) -> $crate::Result<$crate::Page> {
                $crate::page(&b::browse_fetch(url.as_ref()))
            }
        }
    };
    (command) => {
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
    };
    (parallel) => {
        pub mod parallel {
            use super::b;
            /// Fan a registered command over `inputs` (one stdin each), concurrently
            /// across isolated instances — the host (BEAM) does the distribution a
            /// single-threaded wasm instance can't. Per-input results, IN ORDER.
            pub fn map(name: impl AsRef<str>, inputs: &[&str]) -> $crate::Result<Vec<$crate::Result<String>>> {
                let inputs_json = serde_json::to_string(inputs)
                    .map_err(|e| $crate::DockError(format!("encode inputs: {e}")))?;
                $crate::parse_many(&b::run_command_many(name.as_ref(), &inputs_json))
            }
        }
    };
    // `frames` (shared-frame arena) is not yet built — host side wb-rhs.5/wb-pkh.8.
    ($other:ident) => {
        compile_error!(concat!(
            "dock::bind! — unknown or not-yet-available cap `", stringify!($other),
            "` (known: command, llm, vfs, browse, parallel)"
        ));
    };
}

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

    #[test]
    fn parse_many_splits_ok_and_error_per_worker() {
        let v = parse_many(r#"[{"ok":"cba"},{"error":"boom"},{"ok":"zyx"}]"#).unwrap();
        assert_eq!(v.len(), 3);
        assert_eq!(v[0].as_ref().unwrap(), "cba");
        assert!(v[1].is_err());
        assert_eq!(v[2].as_ref().unwrap(), "zyx");
    }
}
