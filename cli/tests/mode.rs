//! Mode-model contract tests: envelope shape + exit-code map (cli/SPEC.md).
use std::process::Command;

fn wbx() -> Command {
    Command::new(env!("CARGO_BIN_EXE_wbx"))
}

#[test]
fn json_envelope_on_success() {
    let dir = std::env::temp_dir().join("wbx-mode-test");
    std::fs::create_dir_all(&dir).unwrap();
    let f = dir.join("ok.html");
    std::fs::write(&f, "<work-task title=\"hello\"></work-task>\n").unwrap();
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
    let f = dir.join("plain.html");
    std::fs::write(&f, "<work-task title=\"hello\"></work-task>\n").unwrap();
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
    let org = name.join("index.html");
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
    assert!(manifest.contains("** dependency audit (static, auto)"), "import auto-runs stage 2");
    // run.sh is plain sh → all-ready → the plan honestly has nothing to do
    assert!(manifest.contains("** fix-up plan"), "stage-3 plan present");
    assert!(manifest.contains("nothing to fix"), "all-ready plan is honest");
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

#[test]
fn toolkit_audit_classifies_against_the_lanes() {
    let dir = std::env::temp_dir().join(format!("wbx-audit-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join("scripts")).unwrap();
    std::fs::write(
        dir.join("manifest.org"),
        "#+TOOLKIT: demo\n\n* demo\n\n** TODO dependency audit\n   stage 2 pending\n",
    ).unwrap();
    // posix shell + network binary → convertible (Dock-brokered net)
    std::fs::write(dir.join("scripts/fetch.sh"), "#!/bin/bash\ncurl -s https://x.dev | head\n").unwrap();
    // node + bare npm require → convertible (npm bundle lane)
    std::fs::write(dir.join("scripts/tool.js"), "#!/usr/bin/env node\nconst axios = require('axios');\n").unwrap();
    // python → blocked (no lane)
    std::fs::write(dir.join("scripts/calc.py"), "#!/usr/bin/env python3\nimport numpy\n").unwrap();

    let out = wbx()
        .args(["--json", "toolkit", "audit", dir.to_str().unwrap()])
        .output().unwrap();
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let v: serde_json::Value =
        serde_json::from_slice(&out.stdout).expect("envelope parses");
    assert_eq!(v["ok"], true);
    assert_eq!(v["verb"], "toolkit audit");
    let scripts = v["data"]["scripts"].as_array().unwrap();
    assert_eq!(scripts.len(), 3);
    let class_of = |f: &str| {
        scripts.iter().find(|s| s["file"] == f).unwrap()["class"].as_str().unwrap().to_string()
    };
    assert_eq!(class_of("calc.py"), "blocked", "python has no lane");
    assert_eq!(class_of("fetch.sh"), "convertible", "curl needs Dock-brokered net");
    assert_eq!(class_of("tool.js"), "convertible", "bare npm dep needs bundling");
    assert_eq!(v["data"]["summary"]["blocked"], 1);

    // findings landed in the manifest, stage-1 TODO replaced, stage-3 handoff left
    let m = std::fs::read_to_string(dir.join("manifest.org")).unwrap();
    assert!(m.contains("** dependency audit (static, auto)"));
    assert!(!m.contains("** TODO dependency audit"));
    assert!(m.contains("npm =axios="), "npm dep surfaced");
    assert!(m.contains("pip =numpy="), "pip dep surfaced");

    // stage 3: the plan is the agent manual — one TODO per non-ready script,
    // concrete steps, the done-test spelled out
    assert!(m.contains("** TODO fix-up plan [0/3]"), "plan counts the work: {m}");
    assert!(m.contains("*** TODO calc.py (blocked — python3)"));
    assert!(m.contains("rewrite in JS for the quickjs lane"), "python recipe names the lane");
    assert!(m.contains("route HTTP through the Dock"), "curl recipe is concrete");
    assert!(m.contains("=wbx toolkit build= bundles it via the npm lane"), "npm recipe");
    assert!(m.contains("wbx toolkit verify demo"), "done-test names the real id");

    // --fix with no engine reachable → the standard engine exit code, no panic
    let fix = wbx()
        .args(["toolkit", "audit", dir.to_str().unwrap(), "--fix"])
        .env("WBX_ENGINE_URL", "http://127.0.0.1:1")
        .output().unwrap();
    assert_eq!(fix.status.code(), Some(3), "fix needs an engine: {}", String::from_utf8_lossy(&fix.stderr));

    // human mode: summary line, exit 0
    let h = wbx().args(["toolkit", "audit", dir.to_str().unwrap()]).output().unwrap();
    assert!(h.status.success());
    let txt = String::from_utf8_lossy(&h.stdout);
    assert!(txt.contains("ready") && txt.contains("blocked"), "summary present: {txt}");
}

#[test]
fn toolkit_import_taxonomy_mcp_openapi_npm_pip_guidance() {
    let dir = std::env::temp_dir().join(format!("wbx-tax-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();

    // mcp-server: skill per server, launch synthesized as the bin, env VALUES never leak
    let mcp = dir.join(".mcp.json");
    std::fs::write(&mcp, r#"{"mcpServers": {"gh": {"command": "npx", "args": ["-y", "@x/server"], "env": {"TOKEN": "hunter2"}}}}"#).unwrap();
    let out_dir = dir.join("mcp-tk");
    let out = wbx().args(["toolkit", "import", mcp.to_str().unwrap(), "--out", out_dir.to_str().unwrap()]).output().unwrap();
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let launch = std::fs::read_to_string(out_dir.join("scripts/gh.sh")).unwrap();
    assert!(launch.contains("exec npx -y @x/server"), "server launch is the bin");
    let skill = std::fs::read_to_string(out_dir.join("skills/gh.org")).unwrap();
    assert!(skill.contains("TOKEN"), "env NAME documented");
    for f in ["manifest.org", "skills/gh.org", "scripts/gh.sh"] {
        let body = std::fs::read_to_string(out_dir.join(f)).unwrap();
        assert!(!body.contains("hunter2"), "secret leaked into {f}");
    }

    // openapi (json): skill per operation, engine-HTTP note
    let api = dir.join("api.json");
    std::fs::write(&api, r#"{"openapi":"3.0.0","info":{"title":"Pet Store"},"paths":{"/pets":{"get":{"operationId":"listPets","summary":"List"},"post":{"operationId":"createPet"}}}}"#).unwrap();
    let api_tk = dir.join("api-tk");
    assert!(wbx().args(["toolkit", "import", api.to_str().unwrap(), "--out", api_tk.to_str().unwrap()]).output().unwrap().status.success());
    assert!(api_tk.join("skills/listpets.org").is_file() && api_tk.join("skills/createpet.org").is_file());
    assert!(std::fs::read_to_string(api_tk.join("skills/listpets.org")).unwrap().contains("Dock-brokered"));
    // yaml spec → honest convert-it hint, mapped error (no panic)
    let yml = dir.join("api.yaml");
    std::fs::write(&yml, "openapi: 3.0.0\npaths:\n").unwrap();
    let bad = wbx().args(["toolkit", "import", yml.to_str().unwrap()]).output().unwrap();
    assert!(!bad.status.success());
    assert_ne!(bad.status.code(), Some(101));
    assert!(String::from_utf8_lossy(&bad.stderr).contains("yq"), "yaml hint teaches the fix");

    // npm-cli: bin carried, scoped name stripped
    let npm = dir.join("npmpkg");
    std::fs::create_dir_all(&npm).unwrap();
    std::fs::write(npm.join("package.json"), r#"{"name":"@acme/huniq","description":"dedupe","bin":{"huniq":"cli.js"}}"#).unwrap();
    std::fs::write(npm.join("cli.js"), "#!/usr/bin/env node\nconst c = require('commander');\n").unwrap();
    std::fs::write(npm.join("README.md"), "# huniq\n").unwrap();
    let npm_tk = dir.join("npm-tk");
    assert!(wbx().args(["toolkit", "import", npm.to_str().unwrap(), "--out", npm_tk.to_str().unwrap()]).output().unwrap().status.success());
    let m = std::fs::read_to_string(npm_tk.join("manifest.org")).unwrap();
    assert!(m.contains("#+TOOLKIT: huniq"), "scope stripped: {m}");
    assert!(npm_tk.join("scripts/cli.js").is_file(), "bin carried for the audit");
    assert!(m.contains("npm =commander="), "audit saw the dep");

    // pip-cli: console script synthesized → audit says blocked, plan says rewrite
    let py = dir.join("pypkg");
    std::fs::create_dir_all(&py).unwrap();
    std::fs::write(py.join("pyproject.toml"), "[project]\nname = \"pycli\"\ndescription = \"py tool\"\n\n[project.scripts]\npycli = \"pycli.main:run\"\n").unwrap();
    let py_tk = dir.join("py-tk");
    assert!(wbx().args(["toolkit", "import", py.to_str().unwrap(), "--out", py_tk.to_str().unwrap()]).output().unwrap().status.success());
    let m = std::fs::read_to_string(py_tk.join("manifest.org")).unwrap();
    assert!(m.contains("** TODO fix-up plan [0/1]"), "python entry is real work: {m}");
    assert!(m.contains("quickjs lane"), "plan carries the rewrite recipe");

    // agents-md: guidance-only landing
    let ag = dir.join("AGENTS.md");
    std::fs::write(&ag, "# Rules\n\nBe terse.\n").unwrap();
    let ag_tk = dir.join("ag-tk");
    assert!(wbx().args(["toolkit", "import", ag.to_str().unwrap(), "--out", ag_tk.to_str().unwrap()]).output().unwrap().status.success());
    let m = std::fs::read_to_string(ag_tk.join("manifest.org")).unwrap();
    assert!(m.contains("nothing to fix"), "guidance-only is a clean landing");
}
