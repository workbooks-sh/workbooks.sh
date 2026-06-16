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

## Proven end-to-end (2026-06-15) — Codex AND Claude Code

A krunvm microVM (Linux aarch64 via libkrun/HVF):
- boots from the host; reads a **bidirectional** worktree volume mount;
- has **network egress** to the model APIs (DNS + TLS);
- ran **Codex authenticated with the user's real ChatGPT subscription**
  (`codex login status` → "Logged in using ChatGPT", from the copied-in
  `~/.codex/auth.json`), model `gpt-5.5`;
- **edited the mounted worktree** (`codex exec` created `HELLO.txt`; the host saw
  the change) — the full read→reason→edit→write-back loop, ~8s once installed.

Claude Code path **also proven** (2026-06-15): the macOS-Keychain bridge carries the
subscription into the VM — `claude 2.1.177` authenticated and replied from the
bridged credentials.

### Gotchas (all encoded in `acp-run.sh`)
1. **Scrub to an ASCII environment** before invoking krunvm — a non-ASCII host env
   var panics libkrun's kernel-cmdline builder (`InvalidAscii`). Run under
   `env -i HOME=… PATH=/opt/homebrew/bin:… LANG=C LC_ALL=C`.
2. **Guest script via the volume**, not quoted `--` args (nested quoting across the
   VM boundary gets mangled). Stream guest output to a file on the mount
   (`/work/.acp/out.log`) to watch progress live from the host.
3. **Mount paths must be a direct child of `/`** (krunvm limit) — auth lands at
   `/agentauth`, and we point `CODEX_HOME`/`CLAUDE_CONFIG_DIR` at it.
4. **Copy auth into a throwaway dir; never rw-mount the real `~/.codex`** — the
   agent writes cache/history and would pollute (and re-own) your real config.
5. **The node base lacks `ca-certificates`** → the agent's TLS to the model API
   fails (`no native root CA certificates found`); install it in-VM on first boot.
6. **Disable the agent's OWN sandbox** (`--sandbox danger-full-access`) — the
   microVM IS the isolation boundary; the agent's inner bubblewrap is redundant and
   fights the virtiofs mount (`bwrap` over `/work` → permission denied).

## Auth (the key difference per agent)

| Agent       | Auth storage                              | In-VM strategy |
|-------------|-------------------------------------------|----------------|
| **Codex** ✅ | `~/.codex/auth.json` (file)               | copy `auth.json`+`config.toml` → `/agentauth`, `CODEX_HOME=/agentauth` (PROVEN: carries the ChatGPT subscription) |
| OpenRouter  | API key (env)                             | pass as env var (trivial) |
| **Claude Code** | **macOS Keychain** (`Claude Code-credentials`) | bridge: `security find-generic-password -s "Claude Code-credentials" -w` → temp `.credentials.json`, mount → `/agentauth`, `CLAUDE_CONFIG_DIR=/agentauth` (PROVEN: carries the Claude subscription) |

Claude Code has **no** file credential on macOS, so mounting `~/.claude` alone does
NOT carry the subscription — the keychain bridge is required.

## Use

```sh
WB_ACP_EXPERIMENTAL=1 ./acp-run.sh codex  /path/to/worktree "summarize the repo and list TODOs"
WB_ACP_EXPERIMENTAL=1 ./acp-run.sh claude /path/to/worktree "fix the failing test in foo.ex"
```

No build step required: `acp-run.sh` boots the **node base image** and installs the
agent **inside the VM** on first boot (the bare Mac can't build a custom image —
buildah can't run `RUN` steps without Docker/colima, which are off here). The VM is
created per run and deleted on exit; the worktree is the only shared state (plus the
copied-in, throwaway auth dir).

### Optional speed-up: prebuilt image
On a machine with a running Linux builder (Docker/colima), pre-bake the agents so
each run skips the ~1–2 min in-VM install:
```sh
docker build --platform linux/arm64 -t localhost/wb-acp-agent:latest -f Dockerfile.agent .
skopeo copy docker-daemon:localhost/wb-acp-agent:latest containers-storage:localhost/wb-acp-agent:latest
```
`acp-run.sh` auto-detects `localhost/wb-acp-agent` in containers-storage and uses it.
(`build.sh` runs the buildah path, which only works where buildah can execute `RUN`.)
