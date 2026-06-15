# ACP Desktop Broker — host-side delegation to the user's OWN native coding agent

Status: **DESIGN**. The desktop-only redesign of external-agent delegation. Supersedes the
always-on / guest-reachable `acp-orchestration` broker (`Workbooks.ExternalAgent`), which was
found insecure in multi-tenant by construction. This document is the canon for the desktop
broker; the wire mapping (ACP JSON-RPC, §3/§6 of `acp.md`) is REUSED verbatim — only the
*posture* and *reachability* change.

---

## 0. The one paragraph that matters

The broker spawns the user's **OWN** native `claude` / `codex` binary — a real OS process —
**not** a platform-pinned `/opt/wb/agents/...` binary. It is legitimate for exactly the
reason Zed and Cursor are: it is the user's own tool, on the user's own machine, using the
user's own subscription. We speak ACP over its stdio (`initialize → authenticate →
session/new → session/prompt → stream session/update`) and map each `session/update` into
`Workbooks.Workflow.Telemetry` so the sub-agent's steps join the parent DAG. The ENTIRE
surface is `WB_DESKTOP`-only and host-side: it can never start, never be reachable, in the
cloud/multi-tenant runtime, and the in-wasm guest can never reach it. That single posture
predicate is the load-bearing safety property — the insecure class is **closed by
construction**, not patched.

### What changed from `acp-orchestration` (and why the old design was insecure)

| Axis | Old `Workbooks.ExternalAgent` (insecure) | This `Workbooks.AcpDesktopBroker` |
|---|---|---|
| Posture | **Always-on** — started in the supervision tree unconditionally | **`WB_DESKTOP=1 AND not Tenancy.multi?`** — never starts otherwise |
| Reachability | A **guest/agent `delegate` tool** in `agent.ex` — the in-wasm agent could ask for a spawn | **Desktop-orchestration capability only** — NOT a guest tool, no agent-loop reachability |
| Binary | Platform-pinned `/opt/wb/agents/claude-code-acp` w/ pinned sha256 | The **user's OWN** `claude`/`codex` on their machine (the Zed/Cursor model) |
| Auth | Host injects `ANTHROPIC_API_KEY` from `secret_broker` | The binary uses its **OWN subscription OAuth** it already holds; we never read/proxy it |
| Tenancy | Multi-tenant — one principal's grant in a shared process | **Single user** — no multi-tenant concern exists |

The old broker's failure mode was structural: *always-on* + *guest-reachable* in a
*multi-tenant* process means a tenant's wasm guest could induce the host to spawn a trusted
OS subprocess in a shared blast radius. This redesign removes all three legs of that — the
surface is gated off in multi-tenant, it is not wired to the guest at all, and there is only
ever one user. There is nothing to spoof and nothing for a guest to reach.

---

## 1. The posture gate — the single load-bearing predicate

Mirror `Workbooks.Harness` exactly (`runtime/host/harness.ex`). That module already encodes
the precise predicate for the desktop-first exec/creds/oauth surface; the ACP broker is the
same *class* of surface (a desktop-first primitive that has no place in a hosted runtime), so
it gates on the same posture.

```elixir
defmodule Workbooks.AcpDesktopBroker.Gate do
  @moduledoc """
  Posture predicate for the ACP desktop broker. The broker spawns the USER'S OWN native
  coding agent (claude/codex) as a real OS process and relays ACP over its stdio. That is a
  DESKTOP-ORCHESTRATION capability — legitimate on a single-user desktop (the Zed/Cursor
  model), categorically wrong in a multi-tenant hosted runtime. This is the single source of
  truth for "may the ACP broker exist / be reached?".
  """

  @doc "True iff (WB_DESKTOP=1 or WB_ACP_DESKTOP=1) AND NOT multi-tenant hosted."
  def enabled? do
    requested?() and not Workbooks.Tenancy.multi?()
  end

  defp requested? do
    System.get_env("WB_DESKTOP") == "1" or System.get_env("WB_ACP_DESKTOP") == "1"
  end
end
```

This predicate is consulted in **three** independent places (defense in depth — any one
suffices, all three agree):

1. **Supervision start.** `Workbooks.Application` gates the broker's child-spec on
   `Gate.enabled?/0` — exactly as it gates `ExecLoopback` on `Harness.enabled?/0`. In a
   hosted/multi-tenant runtime the broker GenServer/registry is **never started**; there is
   no process to message, no port to bind.
2. **Every public entry (`spawn/await/kill`).** Each re-checks `Gate.enabled?/0` and
   fail-closes with `{:error, :acp_desktop_only}`. So even a stray internal caller in the
   wrong posture is refused at the function boundary, not only at startup.
3. **Not wired to the guest.** There is no `delegate` tool, no `@exec_tools` entry, no Dock
   import, no loopback route. The in-wasm guest has **no name** for this capability. (This is
   the deliberate divergence from `acp.md §7` — that named tool is **deleted** in the desktop
   design.) The guest cannot reach what it cannot name.

`Tenancy.multi?/0` is `WB_TENANCY_MODE == "multi"` (`runtime/host/tenancy.ex`). The hosted
control plane / PCP always runs multi; the packaged desktop never does. So the cloud can
never flip this on, and the desktop never flips it off.

---

## 2. The broker — `Workbooks.AcpDesktopBroker`

File: `runtime/host/acp_desktop_broker.ex`. A GenServer per delegation handle (lifetime ==
the agent subprocess), spawned by an `:os.spawn_executable` Port, mirroring the Port +
`setsid` + process-group-kill discipline from `ProcessBroker` / `ExecLoopback`'s spawn lane.

```elixir
defmodule Workbooks.AcpDesktopBroker do
  @moduledoc """
  Host-side ACP relay to the USER'S OWN native coding agent on a single-user desktop.
  WB_DESKTOP-only (Gate). Spawns the user's claude/codex binary, speaks ACP over its stdio,
  maps session/update into Workflow.Telemetry. The guest can never reach this.
  """

  @type handle :: %{ref: reference, port: port, os_pid: non_neg_integer,
                    pid: pid, bin: String.t, workdir: String.t,
                    session_id: String.t | nil, agent_id: String.t}

  @doc "Gate-checked. Resolve the user's own binary → Port spawn → ACP initialize+session/new.
        Non-blocking; returns once a session id is open. Fail-closed on posture/allowlist."
  @spec spawn(agent_id :: String.t, task :: String.t, opts :: keyword)
        :: {:ok, handle} | {:error, atom}

  @doc "Send session/prompt and block until {stopReason} or wall-clock/idle deadline.
        Streams session/update → telemetry adapter throughout. Reaps + tears down once."
  @spec await(handle, timeout_ms :: non_neg_integer)
        :: {:ok, %{stop_reason: String.t, output: String.t, artifacts: [String.t], usage: map}}
         | {:error, atom}

  @doc "session/cancel notification then kill the process group. Idempotent."
  @spec kill(handle) :: :ok

  @doc "Logical agent ids the desktop permits (claude | codex), resolved to the user's OWN bin."
  @spec agents() :: [String.t]
end
```

`spawn/3` decision order (fail-closed): `Gate.enabled?` → resolve allowlisted agent id →
resolve the **user's own** binary path → confine workdir → Port spawn → ACP handshake.

### 2.1 Resolving the user's OWN binary (NOT a platform binary)

This is the core divergence from `acp.md §4.1`. We do **not** pin a platform sha256 of
`/opt/wb/agents/...`. We locate the binary the user already installed, the way Zed/Cursor do:

```elixir
@agents %{
  "claude" => %{acp_argv: ["--acp"],            # or the user's claude-code-acp bridge, see §5.4
                discover: ["claude"],            # PATH name to look up
                user_store: "~/.claude"},        # the binary's OWN cred store (we never read it)
  "codex"  => %{acp_argv: ["acp"],
                discover: ["codex"],
                user_store: "~/.codex"}
}
```

Resolution order, all confined to the user's machine:
1. An **explicit desktop-config path** the user set (Settings → "Claude binary"), if present.
   The user nominating their own binary is the trust anchor — it is *their* tool.
2. Else the desktop resolves it via the Tauri side (it knows the user's real `$PATH`,
   `~/.local/bin`, Homebrew, the official installer location) and hands the **absolute path**
   to the runtime. The runtime does NOT trust the runtime-process `$PATH` (PATH-injection
   defense); it spawns by the **absolute path the desktop resolved**.
3. Unknown agent id or unresolved binary → `{:error, :agent_not_installed}` (fail-closed,
   surfaced to the desktop UI as "Claude not found — set its path in Settings").

There is no sha256 pin because the binary is the *user's*, updated by the user's own package
manager — pinning a platform hash would be wrong and would break on every `claude` update.
The trust model is "the user's own tool on the user's own machine," not "platform-vetted
binary." (See §4.)

### 2.2 Spawn shape

`task` is delivered as the ACP `session/prompt` payload — **never** interpolated into argv
(structural, not shell; no arg-smuggling). The Port is opened with a minimal allowlisted
`:env`, `:cd` set to the confined workdir, wrapped in `setsid` so the whole process group is
killable on timeout/cancel. `stdout` is the ACP channel (newline-delimited JSON-RPC);
`stderr` is drained to a per-handle log and **never parsed** as protocol.

---

## 3. The ACP wire flow (REUSED from `acp.md §3` — unchanged)

ACP is JSON-RPC 2.0, `protocolVersion: 1`, newline-delimited over the subprocess's stdin
(client→agent) / stdout (agent→client). **We are the client; the user's agent is the
server.**

```
AcpDesktopBroker.spawn(agent_id, task, opts)
  Gate.enabled?  +  resolve user's OWN bin  +  confine workdir          # §1, §2.1, §5
  open_port(user_bin, acp_argv, env: minimal, cd: workdir)
  → initialize {protocolVersion:1, clientCapabilities:{fs, terminal}}
  ← initialize result {agentCapabilities, authMethods}
  [→ authenticate {methodId}]          # ONLY if authMethods non-empty — §4.1; agent uses
                                        # its OWN subscription OAuth it already holds
  → session/new {cwd: workdir, mcpServers: []}
  ← {sessionId}
─ AcpDesktopBroker.await(handle) ────────────────────────────────────────────
  → session/prompt {sessionId, prompt:[{type:"text", text: task}]}
loop until result:
  ← session/update (thought/message/tool_call/plan/usage)  → telemetry adapter (§6)
  ← session/request_permission                              → host answers from desktop policy (§4.2)
  ← fs/read_text_file | fs/write_text_file                  → served INSIDE workdir only (§5)
  ← terminal/*                                              → served inside the workdir confine (§5)
  [→ session/cancel  on kill/await-timeout]
  ← session/prompt result {stopReason}                      → await/2 resolves
  reap, harvest workdir artifacts (capped), tear down once
```

`stopReason ∈ end_turn | max_tokens | max_turn_requests | refusal | cancelled`. Paths
absolute, line numbers 1-based, `sessionId` ↔ `handle.session_id`. The `session/update`
variants consumed: `agent_message_chunk`, `agent_thought_chunk`, `tool_call`,
`tool_call_update`, `plan`, `usage_update`.

---

## 4. Security model — single-user desktop

The threat model is **single-user**: one human, their machine, their tools, their
subscription. There is **no** cross-tenant axis, no shared blast radius, no untrusted
multi-tenant guest in the same process. That collapses most of `acp.md §4/§5`'s machinery
(per-principal Policy clamping, tenant ceilings) to nothing — but four concrete controls
remain and are the whole security surface:

### 4.1 The subscription token stays in the binary's OWN store — we never touch it
The user's `claude`/`codex` already holds its subscription OAuth in its own store
(`~/.claude`, `~/.codex`). When ACP `initialize` returns `authMethods`, the agent
authenticates **with its own held credential** — we send `authenticate {methodId}` to tell it
*which* method, but we never read, proxy, inject, or store the token. This is the opposite of
`acp.md §5.5` (which injected `ANTHROPIC_API_KEY` from `secret_broker`). Here:
- We do NOT set `ANTHROPIC_API_KEY` or any provider key in the Port `:env`.
- We do NOT read `~/.claude/.credentials.json`.
- The bearer is direct user-agent → provider, exactly as when the user runs `claude` in a
  terminal. The desktop `keychain.rs` / `network.rs` OAuth machinery is **not** in this path —
  the agent owns its own auth.

This is the cleanest possible posture: the most sensitive secret (the subscription token)
never crosses our membrane at all.

### 4.2 Allowlist the agent binaries
Only known logical ids spawn — `agents()` returns `["claude", "codex"]`. An unknown id →
`{:error, :unknown_agent}`. The id is logical; the user never names a raw path through this
API (the desktop resolves the absolute path, §2.1). New agents are added to `@agents`
explicitly, never inferred. `session/request_permission` from the agent is answered from a
simple desktop policy (default: prompt the user in the desktop UI, or an auto-allow setting
the user chose) — there is no tenant Policy to consult.

### 4.3 Confine the spawned agent's workdir to a chosen project dir
The user chooses a **project directory** for the delegation (the desktop picks it; default =
the current workbook/project root). The agent is spawned with `cd: project_dir` and ACP
`session/new {cwd: project_dir}`. ACP `fs/*` and `terminal/*` are served **only inside** that
dir:
- Enforcement is structural where the OS allows it: on macOS a `sandbox-exec` profile denying
  `file-write*` outside `project_dir`; the agent's own permission model is a second layer.
- `fs/read_text_file` / `fs/write_text_file` requests with a path outside `project_dir` are
  refused by the broker before the syscall (path canonicalization + prefix check) — `../` and
  symlink escape are checked, and where `sandbox-exec` is active the kernel denies them too.
- This is a *confinement of the user's own tool to the user's chosen project*, not a
  multi-tenant jail — the user could run the same agent unconfined in a terminal; we simply
  scope the delegated run to the project they pointed at.

### 4.4 Lifetime + cancellation (non-cooperative backstops)
`wall_clock_ms` (default 600_000) and an `idle_ms` (default 120_000, kill if no ACP output)
deadline. On either, send ACP `session/cancel`, then `kill -KILL` the whole process group
(the `setsid` wrapper makes the group killable; `:os.cmd` is forbidden by the sandbox
invariant — use the Port / `:erlang.open_port` teardown). `kill/1` is the user's "stop"
button. Reap is once-only.

### 4.5 What is explicitly NOT a concern here (and why)
- **No multi-tenant isolation** — one user; there is no second tenant to isolate from.
- **No per-principal Policy clamping** — no tenant profile ceiling exists on the desktop; the
  controls above are absolute, not derived from a tenant cap.
- **No guest reachability** — §1.3; the guest has no name for this surface.
- **No sandbox-invariant regression** — the in-wasm sandbox is untouched; this surface lives
  entirely host-side and is never exposed to the guest, so `sandbox_invariant_test.exs` is
  unaffected (it forbids guest argv→OS exec; this is a host-side spawn of the user's own
  tool, gated off in any shared runtime).

---

## 5. Enforcement details

| Control | Mechanism |
|---|---|
| Posture | `Gate.enabled?` at supervision start AND every public fn (§1) |
| Binary | absolute path resolved by the desktop (the user's own install); runtime `$PATH` not trusted (§2.1) |
| Task injection | `task` → ACP `session/prompt` payload only, never argv (§2.2) |
| Workdir | `cd: project_dir` + `session/new {cwd}` + `fs/*`/`terminal/*` prefix-confined + macOS `sandbox-exec` (§4.3) |
| Env | minimal allowlist `:env`; NO provider keys injected (§4.1) |
| Secrets | subscription token stays in the agent's own store; never read/proxied (§4.1) |
| Lifetime | `wall_clock_ms` + `idle_ms` → `session/cancel` + process-group `kill -KILL` (§4.4) |
| stderr | drained to a per-handle log, never parsed as protocol (§2.2) |

### 5.4 Bridge binaries
Many agents are not natively ACP. Where the user has a bridge (e.g. `claude-code-acp` that
wraps the real `claude`), the desktop resolves the bridge's absolute path as the binary; it
speaks ACP on its stdio and internally drives the user's `claude` with the user's own auth.
The bridge is still the **user's own** install (npm/`bunx`), resolved like §2.1 — not a
platform-pinned artifact.

---

## 6. Telemetry mapping — ACP events → the shared DAG (REUSED from `acp.md §6`)

Telemetry is automatic at one chokepoint and aggregated by `workdir`.
`Workbooks.Workflow.Telemetry` reads `<workdir>/_steps.jsonl` (`ingest_steps` / `summary` /
`read_steps` / `index`), so all steps written to the same workdir roll into the same run,
grouped by an `agent` tag, observable mid-flight.

**Adapter rule:** the broker relays with `workdir = the parent run's workdir` and tags every
emitted step with a distinct `agent: <agent_id>` (e.g. `"claude"`). Each ACP `session/update`
is translated to the standard step-event shape and **appended to the same `_steps.jsonl`** —
the delegated sub-agent's steps join the parent DAG with no change to `Telemetry`.

Step-event shape (match the existing one exactly):
`{step, agent, tool, args, output, exit_code, error, dur_ms, ts}`.

| ACP `session/update` variant | Step event |
|---|---|
| `tool_call` (status `pending`) | open a step: `tool=kind`, `args=rawInput`, `agent=<id>`, `ts` now; key by `toolCallId` |
| `tool_call_update` (status `completed`) | close the step: `output=content/rawOutput`, `exit_code=0`, `dur_ms` |
| `tool_call_update` (status `failed`) | close the step: `error=…`, `exit_code≠0` |
| `agent_message_chunk` | accumulate assistant text into the owning step's `output` |
| `agent_thought_chunk` | optional `think`-kind step (reasoning trace), same shape |
| `plan` | one `tool="plan"` step capturing entries (priority/status) |
| `usage_update` | fold `{used,size,cost}` into the run's usage rollup (not a tool step) |
| `session/prompt` result `{stopReason}` | terminal marker; `await/2` returns it |

Group key = `agent` (`<agent_id>`); join key = `workdir`. To fold a delegated external agent
into the same DAG: relay with the parent `workdir` and a distinct `agent:` name. No emit code
needed in `Telemetry`. The desktop reads the live `_steps.jsonl` via `Telemetry.summary/1` to
render the sub-agent's steps in the run view as they stream.

---

## 7. Where it's driven from (NOT the guest)

The desktop UI / the desktop's own orchestration drives this — a desktop control surface (the
Tauri side over the desktop bridge, like `oauth_loopback.ex`'s `DesktopBridge`), or a
host-side desktop command. The user clicks "Delegate to Claude on this project," the desktop
calls `AcpDesktopBroker.spawn/3`, watches `Telemetry.summary/1`, and can hit "stop"
(`kill/1`). This is a **desktop-orchestration** path, not an LLM-agent tool: the in-wasm
agent loop has no `delegate` tool and never reaches the broker. (Contrast `acp.md §7`, whose
guest-facing `delegate` tool is the insecure leg this design removes.)

---

## 8. Plan (build order)

See the structured `plan`. In short: gate first (so the surface can never come up in the
wrong posture), then the broker spawn/relay against the user's own binary, then the telemetry
adapter, then the desktop drive surface, then tests proving the gate is closed in
multi-tenant and the guest has no path.
