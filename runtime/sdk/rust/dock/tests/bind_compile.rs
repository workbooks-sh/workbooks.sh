//! wb-pkh.2 — validate that `dock::bind!` generates VALID, WORKING cap wrappers
//! against real wit-bindgen-shaped binding signatures. Previously only the pure
//! marshalling core was tested; the macro-emitted wrappers (dock::llm/vfs/browse/
//! command/parallel) had never been compiled. Here a stub `bindings` module stands
//! in for cargo-component's generated bindings (same fn signatures), so the macro
//! expansion is type-checked AND the wrapper logic (error envelopes, JSON decode,
//! per-worker parallel results) is exercised — without a full cargo-component/wasm
//! build. Run with all cap features enabled.

// The shape cargo-component generates for the `engine` world (stringly imports).
mod bindings {
    pub fn session_info() -> String {
        r#"{"id":"wb1","tenant":"acme"}"#.into()
    }
    pub fn vfs_query(_sql: &str) -> String {
        r#"[{"n":1},{"n":2}]"#.into()
    }
    pub fn run_command(_name: &str, _input: &str, _args: &[String]) -> String {
        "ran-ok".into()
    }
    pub fn run_command_many(_name: &str, _inputs_json: &str) -> String {
        r#"[{"ok":"cba"},{"error":"boom"}]"#.into()
    }
    pub fn llm_complete(_prompt: &str) -> String {
        "the-reply".into()
    }
    pub fn browse_fetch(_url: &str) -> String {
        r#"{"url":"https://x","title":"X","text":"hi"}"#.into()
    }
}

// Expand the SDK macro over the stub bindings — this is the thing that had never
// compiled. If any wrapper is malformed Rust, this test file fails to build.
dock::bind!(bindings);

#[test]
fn llm_wrapper_returns_ok() {
    assert_eq!(llm::ask("hello").unwrap(), "the-reply");
}

#[test]
fn command_wrapper_returns_stdout() {
    assert_eq!(command::run("jq", "{}", &[".x"]).unwrap(), "ran-ok");
}

#[test]
fn vfs_wrapper_decodes_rows() {
    #[derive(serde::Deserialize, PartialEq, Debug)]
    struct R {
        n: i64,
    }
    let rows: Vec<R> = vfs::query("select n").unwrap();
    assert_eq!(rows, vec![R { n: 1 }, R { n: 2 }]);
}

#[test]
fn browse_wrapper_decodes_page() {
    let page = browse::fetch("https://x").unwrap();
    assert_eq!(page.url.as_deref(), Some("https://x"));
    assert_eq!(page.title.as_deref(), Some("X"));
}

#[test]
fn parallel_wrapper_splits_ok_and_error_per_worker() {
    let results = parallel::map("rev", &["abc", "xyz"]).unwrap();
    assert_eq!(results.len(), 2);
    assert_eq!(results[0].as_ref().unwrap(), "cba");
    assert!(results[1].is_err());
}
