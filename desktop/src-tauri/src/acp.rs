// Experimental local-microVM ACP runner (wb ACP).
//
// Drives a local coding-agent CLI (claude, codex) over the ACP orchestrator
// script `acp-run.sh`, inside the libkrun-backed local microVM. This is the
// host (Tauri) half the DetectModal-connected agents shell into.

use serde::Serialize;

#[derive(Serialize)]
pub struct AcpRunResult {
    ok: bool,
    transcript: String,
}

/// service id → ACP agent name the orchestrator script understands.
fn acp_agent(service: &str) -> Option<&'static str> {
    match service {
        "claude_code" => Some("claude"),
        "codex" => Some("codex"),
        _ => None,
    }
}

/// Locate the `acp-run.sh` orchestrator. Resolved from the WB_ACP_RUN env var.
///
// TODO(follow-on): bundle acp-run.sh as a Tauri resource and resolve it via the
// app's resource dir, so it works without the user setting WB_ACP_RUN. Until
// then we never hardcode an absolute repo path — that's session/machine-specific.
fn acp_run_script() -> Result<String, String> {
    std::env::var("WB_ACP_RUN").map_err(|_| {
        "acp-run.sh not found — set WB_ACP_RUN to runtime/acp-local/acp-run.sh".to_string()
    })
}

/// Run a coding agent against a worktree via the ACP orchestrator. Blocking —
/// captures stdout+stderr combined into `transcript`. (Streaming output is a
/// deliberate follow-on.)
#[tauri::command]
pub fn acp_run_agent(
    service: String,
    worktree: String,
    task: String,
) -> Result<AcpRunResult, String> {
    let agent = acp_agent(&service)
        .ok_or_else(|| format!("unsupported ACP service `{service}` (expected claude_code | codex)"))?;
    let script = acp_run_script()?;

    // SCRUBBED, ASCII-ONLY env (the libkrun gotcha — a non-ASCII env var panics
    // the VM builder). env_clear() then only the minimal vars the runner needs.
    let home = std::env::var("HOME").map_err(|_| "HOME not set".to_string())?;

    let output = std::process::Command::new("sh")
        .arg(&script)
        .arg(agent)
        .arg(&worktree)
        .arg(&task)
        .env_clear()
        .env("HOME", home)
        .env("PATH", "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        .env("LANG", "C")
        .env("LC_ALL", "C")
        .env("WB_ACP_EXPERIMENTAL", "1")
        .output()
        .map_err(|e| format!("failed to spawn acp-run.sh: {e}"))?;

    let mut transcript = String::from_utf8_lossy(&output.stdout).into_owned();
    let stderr = String::from_utf8_lossy(&output.stderr);
    if !stderr.is_empty() {
        if !transcript.is_empty() && !transcript.ends_with('\n') {
            transcript.push('\n');
        }
        transcript.push_str(&stderr);
    }

    Ok(AcpRunResult {
        ok: output.status.success(),
        transcript,
    })
}
