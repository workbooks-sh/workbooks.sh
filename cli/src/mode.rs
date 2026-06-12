//! Mode model — two audiences, one binary (cli/SPEC.md § Ergonomics).
//!
//! Detection: `--json` → Json · `--agent`/`WBX_AGENT=1` → Agent · stdout is a
//! TTY → Human · otherwise (piped/redirected) → Agent. Agent mode NEVER
//! prompts and emits NO ANSI; Json mode wraps every outcome in one envelope:
//!
//!   { "ok": bool, "verb": "toolkit list", "data": …,
//!     "error": { "code": n, "message": "…", "hint": "…" } }
//!
//! Exit-code map (stable, for agent branching):
//!   0 ok · 2 usage (clap) · 3 engine unreachable · 4 not found ·
//!   5 verification failed · 6 conflict · 7 auth rejected · 1 everything else

use std::io::IsTerminal;

#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Mode {
    Human,
    Agent,
    Json,
}

pub fn detect(json: bool, agent: bool) -> Mode {
    if json {
        Mode::Json
    } else if agent || std::env::var("WBX_AGENT").map(|v| v == "1").unwrap_or(false) {
        Mode::Agent
    } else if std::io::stdout().is_terminal() {
        Mode::Human
    } else {
        Mode::Agent
    }
}

pub const EXIT_ENGINE: i32 = 3;
pub const EXIT_NOT_FOUND: i32 = 4;
pub const EXIT_VERIFY: i32 = 5;
pub const EXIT_CONFLICT: i32 = 6;
pub const EXIT_AUTH: i32 = 7;

/// Map an error to the stable exit code. Heuristic over the error chain text
/// until errors carry typed codes; the *contract* is the code, not the text.
pub fn classify(err: &anyhow::Error) -> i32 {
    let s = format!("{err:#}").to_lowercase();
    if s.contains("connection refused")
        || s.contains("error sending request")
        || s.contains("runtime.json")
        || s.contains("no runtime")
        || s.contains("tcp connect")
    {
        EXIT_ENGINE
    } else if s.contains("404") || s.contains("not found") || s.contains("no such file") {
        EXIT_NOT_FOUND
    } else if s.contains("signature") || s.contains("integrity") || s.contains("verif") {
        EXIT_VERIFY
    } else if s.contains("409") || s.contains("conflict") {
        EXIT_CONFLICT
    } else if s.contains("401") || s.contains("unauthorized") || s.contains("403") || s.contains("forbidden") {
        EXIT_AUTH
    } else {
        1
    }
}

fn hint(code: i32) -> Option<&'static str> {
    match code {
        EXIT_ENGINE => Some("no engine reachable — start one with `wbx deploy local` or set WB_ENGINE_URL"),
        EXIT_NOT_FOUND => Some("check the path/id — `wbx library`, `wbx toolkit list`, `wbx workbook list` enumerate what exists"),
        EXIT_VERIFY => Some("the artifact failed its trust check — re-sign with `wbx sign` or fetch a clean copy"),
        EXIT_CONFLICT => Some("state moved underneath you — re-read with the matching show/list verb and retry"),
        EXIT_AUTH => Some("the engine rejected your credentials — set WB_ENGINE_TOKEN, or re-run `wbx deploy local` to refresh discovery"),
        _ => None,
    }
}

/// The verb path as invoked (subcommand words only, flags + positionals
/// skipped) — for the envelope. Group verbs contribute their sub-verb.
pub fn verb_path() -> String {
    const GROUPS: &[&str] = &["publish", "toolkit", "workflow", "agent", "workbook", "deploy"];
    let mut words = std::env::args().skip(1).filter(|a| !a.starts_with('-'));
    match words.next() {
        None => String::new(),
        Some(v) if GROUPS.contains(&v.as_str()) => match words.next() {
            Some(sub) => format!("{v} {sub}"),
            None => v,
        },
        Some(v) => v,
    }
}

/// Render a success once, per mode.
pub fn render_ok(mode: Mode, verb: &str, out: &str) {
    match mode {
        Mode::Human | Mode::Agent => {
            if !out.is_empty() {
                println!("{out}");
            }
        }
        Mode::Json => {
            // If the command already produced JSON, embed it structurally.
            let data = serde_json::from_str::<serde_json::Value>(out)
                .unwrap_or_else(|_| serde_json::json!({ "text": out }));
            let env = serde_json::json!({ "ok": true, "verb": verb, "data": data });
            println!("{env}");
        }
    }
}

/// Render a failure once, per mode. Returns the process exit code.
pub fn render_err(mode: Mode, verb: &str, err: &anyhow::Error) -> i32 {
    let code = classify(err);
    match mode {
        Mode::Human | Mode::Agent => {
            eprintln!("wbx: {err:#}");
            if mode == Mode::Human {
                if let Some(h) = hint(code) {
                    eprintln!("     {h}");
                }
            }
        }
        Mode::Json => {
            let env = serde_json::json!({
                "ok": false,
                "verb": verb,
                "error": {
                    "code": code,
                    "message": format!("{err:#}"),
                    "hint": hint(code),
                    "retryable": code == EXIT_ENGINE || code == EXIT_CONFLICT,
                }
            });
            println!("{env}");
        }
    }
    code
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn classify_maps_the_contract_codes() {
        let c = |m: &str| classify(&anyhow::anyhow!(m.to_string()));
        assert_eq!(c("connection refused"), EXIT_ENGINE);
        assert_eq!(c("404: nope"), EXIT_NOT_FOUND);
        assert_eq!(c("No such file or directory"), EXIT_NOT_FOUND);
        assert_eq!(c("signature mismatch"), EXIT_VERIFY);
        assert_eq!(c("409 conflict"), EXIT_CONFLICT);
        assert_eq!(c("401 Unauthorized"), EXIT_AUTH);
        assert_eq!(c("something else entirely"), 1);
    }
}

/// Hand-rolled picker for HUMAN mode only — callers must gate on mode; agent
/// mode never reaches this. Prints the menu to stderr, reads one line.
#[cfg(not(target_arch = "wasm32"))]
pub fn pick(question: &str, options: &[(&str, &str)], default: usize) -> std::io::Result<usize> {
    use std::io::Write;
    let err = std::io::stderr();
    let mut e = err.lock();
    writeln!(e, "? {question}")?;
    for (i, (name, desc)) in options.iter().enumerate() {
        let mark = if i == default { "›" } else { " " };
        writeln!(e, "  {mark} {}) {name:<10} {desc}", i + 1)?;
    }
    write!(e, "  [{}] ", default + 1)?;
    e.flush()?;
    let mut line = String::new();
    std::io::stdin().read_line(&mut line)?;
    let n: usize = line.trim().parse().unwrap_or(default + 1);
    Ok(n.saturating_sub(1).min(options.len() - 1))
}

#[cfg(target_arch = "wasm32")]
pub fn pick(_q: &str, _o: &[(&str, &str)], default: usize) -> std::io::Result<usize> {
    Ok(default)
}

/// Next-verb guidance, HUMAN mode only — the CLI teaches its own grammar.
pub fn next_hint(verb: &str) -> Option<&'static str> {
    Some(match verb {
        "build" => "wbx bundle  (assemble everything into one artifact)",
        "bundle" => "wbx sign <artifact>  (embed provenance)",
        "sign" => "wbx verify <artifact>  ·  wbx workbook deploy <id> <artifact>",
        "deploy init" => "wbx deploy apply  (converge to what you declared)",
        "deploy apply" => "wbx deploy status  ·  wbx deploy logs",
        "toolkit build" => "wbx toolkit push <id>  (ship it onto the engine)",
        "workbook deploy" => "wbx workbook list  (see it living)",
        _ => return None,
    })
}
