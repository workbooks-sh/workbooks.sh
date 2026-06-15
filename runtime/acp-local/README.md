# Local microVM ACP orchestrator (EXPERIMENTAL — wb-xiei.8)

Run your **real** subscribed coding agents (Codex / Claude Code) inside a local
**krunvm microVM**, against a worktree the desktop (Waldo) mounts in. Each agent
gets its own hardware-virtualized Linux kernel — strong isolation, sees only the
mounted worktree + its own auth.

**LOCAL ONLY.** No cloud / no Fly machines (cloud would entangle per-user
subscriptions). Experimental: gated behind `WB_ACP_EXPERIMENTAL`; not a shipping
feature. Orchestration runs **host-side** (krunvm uses libkrun/HVF on the bare
Mac and can't nest inside the runtime container) — this spike is a shell harness;
productionizing moves it into the Tauri desktop layer.

## Proven (2026-06-15)

A krunvm microVM (Linux aarch64 via libkrun/HVF):
- boots from the host;
- reads a **bidirectional** worktree volume mount (`--volume host:/work`);
- has **network egress** (reached `api.anthropic.com` — DNS + TLS + connectivity);
- writes back to the host worktree.

### Gotchas (encoded in `acp-run.sh`)
1. **Scrub to an ASCII environment** before invoking krunvm — a non-ASCII host env
   var panics libkrun's kernel-cmdline builder (`InvalidAscii`). We run it under
   `env -i HOME=… PATH=/opt/homebrew/bin:… LANG=C LC_ALL=C`.
2. **Pass the guest script via the volume**, not as quoted `--` args (nested
   quoting through the VM boundary gets mangled).

## Auth (the key difference per agent)

| Agent       | Auth storage                              | In-VM strategy |
|-------------|-------------------------------------------|----------------|
| **Codex**   | `~/.codex/auth.json` (file)               | mount `~/.codex` → `/root/.codex` (easiest) |
| OpenRouter  | API key (env)                             | pass as env var (trivial) |
| **Claude Code** | **macOS Keychain** (`Claude Code-credentials`) | bridge: `security find-generic-password -s "Claude Code-credentials" -w` → write to a temp `.credentials.json`, mount → `/root/.claude` |

Claude Code has **no** file credential on macOS, so mounting `~/.claude` alone does
NOT carry the subscription — the keychain bridge is required.

## Use

```sh
# 1. Build the agent image (Linux arm64: node + git + codex + claude-code)
./build.sh

# 2. Run a real agent in a throwaway microVM against a worktree
WB_ACP_EXPERIMENTAL=1 ./acp-run.sh codex  /path/to/worktree "summarize the repo and list TODOs"
WB_ACP_EXPERIMENTAL=1 ./acp-run.sh claude /path/to/worktree "fix the failing test in foo.ex"
```

The VM is created per run and deleted on exit; the worktree is the only shared
state (plus the read-only auth mount).
