//! Mode-model contract tests: envelope shape + exit-code map (cli/SPEC.md).
use std::process::Command;

fn wbx() -> Command {
    Command::new(env!("CARGO_BIN_EXE_wbx"))
}

#[test]
fn json_envelope_on_success() {
    let dir = std::env::temp_dir().join("wbx-mode-test");
    std::fs::create_dir_all(&dir).unwrap();
    let f = dir.join("ok.org");
    std::fs::write(&f, "* hello\n").unwrap();
    let out = wbx().args(["--json", "query", f.to_str().unwrap()]).output().unwrap();
    assert!(out.status.success(), "stderr: {}", String::from_utf8_lossy(&out.stderr));
    let v: serde_json::Value = serde_json::from_slice(&out.stdout).expect("stdout is one JSON envelope");
    assert_eq!(v["ok"], true);
    assert_eq!(v["verb"], "query");
    assert!(v.get("data").is_some());
}

#[test]
fn json_envelope_and_code_on_not_found() {
    let out = wbx().args(["--json", "query", "/definitely/not/here.org"]).output().unwrap();
    assert_eq!(out.status.code(), Some(4), "not-found maps to exit 4");
    let v: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(v["ok"], false);
    assert_eq!(v["error"]["code"], 4);
    assert!(v["error"]["message"].as_str().unwrap().len() > 0);
}

#[test]
fn piped_default_is_plain_text_no_envelope() {
    let dir = std::env::temp_dir().join("wbx-mode-test");
    std::fs::create_dir_all(&dir).unwrap();
    let f = dir.join("plain.org");
    std::fs::write(&f, "* hello\n").unwrap();
    // .output() pipes stdout → auto agent mode: plain text, not an envelope
    let out = wbx().args(["query", f.to_str().unwrap()]).output().unwrap();
    assert!(out.status.success());
    let s = String::from_utf8_lossy(&out.stdout);
    assert!(!s.trim_start().starts_with("{\"ok\""), "agent default must not wrap in envelope");
}

#[test]
fn usage_error_is_exit_2() {
    let out = wbx().arg("no-such-verb").output().unwrap();
    assert_eq!(out.status.code(), Some(2), "clap usage errors exit 2");
}
