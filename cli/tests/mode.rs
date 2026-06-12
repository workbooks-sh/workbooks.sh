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

#[test]
fn bare_wbx_is_a_landing_not_a_usage_error() {
    let out = wbx().env("WB_DESKTOP_DIR", "/nonexistent-disco").output().unwrap();
    assert!(out.status.success(), "bare wbx must not be an error");
    // piped → agent mode → doctor JSON body
    let v: serde_json::Value = serde_json::from_slice(&out.stdout).expect("agent landing is structured");
    assert!(v["version"].is_string());
}

#[test]
fn agent_mode_deploy_init_never_prompts() {
    let dir = std::env::temp_dir().join(format!("wbx-pick-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    // piped stdin closed + no preset: agent default must be instant 'local',
    // never a hang on a picker
    let out = wbx()
        .current_dir(&dir)
        .args(["deploy", "init"])
        .stdin(std::process::Stdio::null())
        .output()
        .unwrap();
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let s = String::from_utf8_lossy(&out.stdout);
    assert!(s.contains("local"), "agent default is local: {s}");
    assert!(dir.join("deployment.org").is_file());
}

#[test]
fn status_is_the_landing_and_open_maps_not_found() {
    let out = wbx().arg("status").env("WB_DESKTOP_DIR", "/nonexistent-disco").output().unwrap();
    assert!(out.status.success());
    let v: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert!(v["version"].is_string());
    // open on a missing file → exit 4 (not-found contract)
    let out = wbx().args(["open", "/definitely/not/here.html"]).output().unwrap();
    assert_eq!(out.status.code(), Some(4));
}

#[test]
fn wbx_env_aliases_win_over_wb() {
    // WBX_ENGINE_URL preferred: point it at a dead port and watch the
    // engine-unreachable class (3), proving the alias was read
    let out = wbx()
        .args(["--json", "rt", "status"])
        .env("WBX_ENGINE_URL", "http://127.0.0.1:1")
        .env("WB_ENGINE_URL", "http://127.0.0.1:2")
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(3), "dead engine maps to exit 3");
    let v: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert!(
        v["error"]["message"].as_str().unwrap().contains("127.0.0.1:1"),
        "WBX_ var must take precedence: {}",
        v["error"]["message"]
    );
}

#[test]
fn help_json_emits_the_verb_tree() {
    let out = wbx().args(["help", "--json"]).output().unwrap();
    assert!(out.status.success());
    let v: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(v["ok"], true);
    let subs = v["data"]["subcommands"].as_array().unwrap();
    let names: Vec<&str> = subs.iter().filter_map(|s| s["name"].as_str()).collect();
    for must in ["init", "dev", "toolkit", "deploy", "doctor"] {
        assert!(names.contains(&must), "tree missing {must}");
    }
    // group verbs expose their sub-verbs
    let toolkit = subs.iter().find(|s| s["name"] == "toolkit").unwrap();
    assert!(!toolkit["subcommands"].as_array().unwrap().is_empty());
}

#[test]
fn author_verbs_accept_stdin_dash() {
    use std::io::Write;
    let mut child = wbx()
        .args(["lint", "-"])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.as_mut().unwrap().write_all(b"* hello\n").unwrap();
    let out = child.wait_with_output().unwrap();
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    assert_eq!(String::from_utf8_lossy(&out.stdout).trim(), "[]");
}

#[test]
fn toolkit_import_claude_skill_scaffolds_a_real_toolkit() {
    let dir = std::env::temp_dir().join(format!("wbx-import-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let skill = dir.join("my-skill");
    std::fs::create_dir_all(skill.join("references")).unwrap();
    std::fs::create_dir_all(skill.join("scripts")).unwrap();
    std::fs::write(
        skill.join("SKILL.md"),
        "---\nname: demo-skill\ndescription: does demo things\n---\n# Demo\n\nUse `demo` like [this](https://x.dev).\n\n```bash\necho hi\n```\n",
    ).unwrap();
    std::fs::write(skill.join("references/extra.md"), "# Extra\n\nMore notes.\n").unwrap();
    std::fs::write(skill.join("scripts/run.sh"), "#!/bin/sh\necho hi\n").unwrap();

    let out_dir = dir.join("out");
    let out = wbx()
        .args(["toolkit", "import", skill.to_str().unwrap(), "--out", out_dir.to_str().unwrap()])
        .output().unwrap();
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));

    let manifest = std::fs::read_to_string(out_dir.join("manifest.org")).unwrap();
    assert!(manifest.contains("#+TOOLKIT: demo-skill"), "id from frontmatter");
    assert!(manifest.contains("#+TAGLINE: does demo things"));
    assert!(manifest.contains("TODO dependency audit"), "stage-2 handoff present");
    assert!(manifest.contains("scripts/run.sh"), "carried script listed");
    assert!(out_dir.join("scripts/run.sh").is_file());

    let skill_org = std::fs::read_to_string(out_dir.join("skills/demo-skill.org")).unwrap();
    assert!(skill_org.contains("* Demo"), "md heading became org");
    assert!(skill_org.contains("#+begin_src bash"), "fence became src block");
    assert!(skill_org.contains("[[https://x.dev][this]]"), "link converted");
    assert!(out_dir.join("skills/reference-extra.org").is_file());

    let again = wbx()
        .args(["toolkit", "import", skill.to_str().unwrap(), "--out", out_dir.to_str().unwrap()])
        .output().unwrap();
    assert!(!again.status.success());
}

#[test]
fn toolkit_import_markdown_and_unknown_kind() {
    let dir = std::env::temp_dir().join(format!("wbx-import-md-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let md = dir.join("notes.md");
    std::fs::write(&md, "# Notes\n\nA doc worth keeping.\n").unwrap();
    let out_dir = dir.join("nt");
    let out = wbx()
        .args(["toolkit", "import", md.to_str().unwrap(), "--out", out_dir.to_str().unwrap()])
        .output().unwrap();
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    assert!(out_dir.join("skills/notes.org").is_file());
    let bad = wbx().args(["toolkit", "import", md.to_str().unwrap(), "--as", "vsix"]).output().unwrap();
    assert!(!bad.status.success());
    assert_ne!(bad.status.code(), Some(101), "no panic");
}
