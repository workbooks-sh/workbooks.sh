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

#[test]
fn init_scaffold_lints_and_bundles() {
    let dir = std::env::temp_dir().join(format!("wbx-init-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let name = dir.join("demo");
    let out = wbx().args(["init", name.to_str().unwrap()]).output().unwrap();
    assert!(out.status.success(), "init: {}", String::from_utf8_lossy(&out.stderr));
    let org = name.join("workbook.org");
    assert!(org.is_file() && name.join("data").is_dir());
    // the scaffold must satisfy the rest of the toolchain
    let lint = wbx().args(["lint", org.to_str().unwrap()]).output().unwrap();
    assert!(lint.status.success(), "lint: {}", String::from_utf8_lossy(&lint.stderr));
    let bundle = wbx().args(["bundle", name.to_str().unwrap()]).output().unwrap();
    assert!(bundle.status.success(), "bundle: {}", String::from_utf8_lossy(&bundle.stderr));
    // re-init over an existing dir refuses
    let again = wbx().args(["init", name.to_str().unwrap()]).output().unwrap();
    assert!(!again.status.success());
}

#[test]
fn dev_serves_and_reloads() {
    let dir = std::env::temp_dir().join(format!("wbx-dev-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let name = dir.join("site");
    assert!(wbx().args(["init", name.to_str().unwrap()]).output().unwrap().status.success());
    let mut child = wbx()
        .args(["dev", name.to_str().unwrap(), "--port", "4399"])
        .stderr(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    // wait for the server, then GET /
    let mut ok = false;
    for _ in 0..30 {
        std::thread::sleep(std::time::Duration::from_millis(150));
        if let Ok(mut s) = std::net::TcpStream::connect("127.0.0.1:4399") {
            use std::io::{Read, Write};
            let _ = s.write_all(b"GET / HTTP/1.1\r\nhost: x\r\n\r\n");
            let mut buf = String::new();
            let _ = s.read_to_string(&mut buf);
            if buf.contains("200 OK") && buf.to_lowercase().contains("<html") {
                ok = true;
                break;
            }
        }
    }
    let _ = child.kill();
    assert!(ok, "dev server never answered with HTML");
}

#[test]
fn doctor_reports_and_exits_zero_even_without_engine() {
    // agent default (piped): structured JSON body, exit 0 regardless of engine
    let out = wbx().arg("doctor").env("WB_DESKTOP_DIR", "/nonexistent-disco").output().unwrap();
    assert!(out.status.success(), "doctor must not fail the shell");
    let v: serde_json::Value = serde_json::from_slice(&out.stdout).expect("doctor agent output is JSON");
    assert!(v["engine"]["state"].is_string());
    // --json wraps the same data in the envelope
    let out = wbx().args(["--json", "doctor"]).env("WB_DESKTOP_DIR", "/nonexistent-disco").output().unwrap();
    let v: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(v["ok"], true);
    assert!(v["data"]["engine"]["state"].is_string(), "envelope embeds structured doctor data");
}

#[test]
fn completions_emit_for_zsh_and_bash() {
    for shell in ["zsh", "bash"] {
        let out = wbx().args(["completions", shell]).output().unwrap();
        assert!(out.status.success());
        let s = String::from_utf8_lossy(&out.stdout);
        assert!(s.contains("wbx"), "{shell} script mentions wbx");
        assert!(s.len() > 500, "{shell} script non-trivial");
    }
}
