# the spoken thesis, audited

- Date: 2026-06-10
- Source: `../sources/2026-06-10-spoken-thesis/verbatim.txt` (91 min voice memo, ElevenLabs scribe_v1, 8,578 words)
- Statuses: CLAIMED · VALIDATING | KEPT · PARTIAL · UNKEPT · FUTURE · RETRACTED

## What this document is

On 2026-06-10 Shane recorded a 91-minute unscripted self-talk describing the
workbooks ecosystem as he understands and pitches it: the workbook (the
artifact), the runtime (the server), toolkits (the extension surface), and
the autopoet (the future state). The verbatim transcript lives untouched in
`../sources/2026-06-10-spoken-thesis/`.

This file is the working document built FROM it: every load-bearing claim
the recording makes is extracted as a tracked item with an honesty status —
what the system actually does, what is partially true, what is promised but
unbuilt, and what is pure future state. The audit IS the ideation method:
the gap between the spoken system and the shipped system is the backlog.

Statuses: `CLAIMED` (extracted, not yet checked) → `VALIDATING` (being
checked against the repo) → `KEPT` / `PARTIAL` / `UNKEPT` / `FUTURE`
(intentionally not built yet) / `RETRACTED` (the claim was wrong, drop it
from the pitch). Every terminal status must cite evidence: a file, an epic,
a test, or a live run.

## Prong 1 — the workbook (the artifact)

### KEPT — a workbook is an HTML file: CSS + JS + WebAssembly + SQLite, gzip-packed

Quote: "if you looked at a workbook, you would at first glance see an HTML
file… natively zipped… a SQLite binary file."
Evidence: the workbooks-authoring surface ships single-file `.html`
mini-apps bundling a WASM runtime + SQLite + their own source.

### CLAIMED — SQLite acts as a shippable virtual file system agents work against

Quote: "a shippable virtual file system for any person or agent."
Verify: VFS seam in the runtime (vfs_* dock caps exist); check what the
in-workbook kernel actually exposes today.

### PARTIAL — an agent can run INSIDE an HTML file (kernel-shape workbook)

Quote: "an agent could effectively run inside of an HTML file… run it at
the edge of an HTML file."
Reality: oql.wasm kernel is code-ready but UNDEPLOYED as a toolkit surface;
desktop embeds the kernel for weaving, but "agent fully resident in the
file" is not yet a shipped, demonstrated thing. This is a flagship demo
waiting to exist.

### CLAIMED — a workbook is functionally a container image — carries its packages, installs itself onto a wasmtime instance like a Docker image onto a kernel

Quote: "instead of sending an entire Docker image, you can just send a
workbook."
Verify: how much of the Docker analogy is real today (deploy-kit ships ONE
OCI image; the workbook-as-container story is a different, partially-built
layer). Risk: this is the pitch line most likely to be called out.

## Prong 2 — the runtime

### KEPT — single Elixir server; isolation = BEAM process + wasmtime instance; exactly one NIF (wasmex → wasmtime)

Quote: "we only run one NIF… WasmX runs Wasmtime."
Evidence: runtime/host/*, sandbox-invariant tests; wasmtime-only is settled
policy.

### KEPT — compilers run IN the sandbox: clang (C), zig, rust (mrustc→clang), go (yaegi), JS/TS (quickjs + npm lane)

Quote: "we have implemented custom compilers written in WebAssembly."
Evidence: epic wb-zyl done; compilers ghcr package; recipes in
runtime/compilers/<lang>/.

### UNKEPT — "most of Python" compiles/runs in the sandbox

Quote: "most computation of Rust or most of Python and JavaScript."
Reality: there is NO Python lane in the compiler set (clang / mrustc / zig
/ go-yaegi / quickjs). Either build it or stop saying it.

### PARTIAL — Bash is emulated in WebAssembly; no native exec anywhere

Quote: "Bash is now emulated in WebAssembly."
Reality: posix toolkit shape exists and the no-native-exec invariant is
enforced for compile paths, but a hardened interim real-bash exec tool
still exists (epic wb-9ja is its removal). True direction, not yet a
finished sentence.

### PARTIAL — Rust async/Tokio is outsourced to the BEAM's concurrency

Quote: "utilizing the concurrency of the BeamVM to outsource a lot of the
async processes like Tokio."
Reality: epic wb-dk3 — dock host-fns + build.rs + resolver shipped, but
within-program concurrency offload (wb-y72) is explicitly DEFERRED. The
transcript itself flags "I would need help on this" — honest, keep it
framed as direction.

### CLAIMED — thousands of agents per server, multi-tenant, "insanely high concurrency"

Quote: "I can host thousands of agents and users and organizations all
isolated from each other."
Reality check: the first live autopoet co-tenant run OVERLOADED a 4-agent
crew box ("Main child exited with signal"). Concurrency is architecturally
plausible and empirically unproven. Needs a load benchmark before this
number is ever said out loud to a buyer.

### CLAIMED — Erlang/BEAM "nine 9s" fault tolerance

Quote: "it works 99.999999999% of the time."
This is folklore from one Ericsson AXD301 anecdote; widely contested.
Recommend RETRACT the number, keep the supervision-tree/let-it-crash story
which is true and ours to demonstrate (the worker already proves it:
crash → BLOCKED verdict → issue back to :open).

## Prong 3 — toolkits + the authoring surface

### KEPT — the authoring/config format is parsable, stateful, chronological, in every model's training data

Quote: "what it does excel at for workbooks is being a configuration
language."
Evidence: lifecycle spec, agent defs, plan boards, toolkit manifests —
the engine interprets the declarative layer. (His proposed
benchmark — "ask models the config format from memory" — is a real, cheap eval to
actually run.)

### KEPT — toolkits = skill-trees wrapping CLIs compiled to WASM, run via wb toolkit

Quote: "package up a CLI system by using a WebAssembly compiler… wrap them
in the same skill structure."
Evidence: six EXEC shapes audited; huniq autobuild proof; AUTHORING docs;
autopoet authored a working seo toolkit end-to-end.

### KEPT — toolkits are "the most immature prong"

Self-aware in the transcript and matches the surface map (prompt
auto-injection, third-party signatures, desktop surface all open). Keep —
honesty here is credibility.

### CLAIMED — a homogeneous authoring format beats freeform Markdown because drift is TESTABLE ("I can't write a test suite for Markdown")

This is the single sharpest differentiating argument in the whole
recording. Verify we actually HAVE the thing it implies: a drift
linter/validator for authored artifacts (`wb content check` exists — how much
does it cover?). If we make this fully true, it's the headline.

## Prong 4 — the autopoet (the future state)

### KEPT — the autopoet exists: tenant agents file metacognitive issues; a system agent authors capabilities into the declarative layer, never native code

Evidence: epic wb-9ae phases 1–3+5 shipped; PROVEN end-to-end (seo
toolkit); crew agent organically filed a real bug unprompted.

### FUTURE — the autopoet as a non-LLM model (state-space / Mamba-class) trained on homogeneous runtime telemetry, diffusing changes into the runtime ("Canopy")

Quote: "not an LLM that is able to view and observe… something closer to
Mamba… make decisions that can be diffused into the runtime."
Reality: today's autopoet is an LLM agent on a poll loop. Canopy is a
research direction, not a feature. The honest dependency chain the
transcript itself states: homogeneous authoring → consistent telemetry →
trainable data → THEN a learned supervisor. OTel wiring (WASI-OTEL spike)
is the unbuilt first rung.

### CLAIMED — the system already emits/uses OpenTelemetry standards

Quote: "taking the open telemetry standards that the system uses."
Verify: WASI-OTEL is a spike doc, not a wired pipeline. Likely UNKEPT
as stated.

## The argument structure (what the pitch actually is)

1. Agents are long-running, stateful, chronological — everything serverless
   and micro-VM assumes the opposite. (Agents = "LLMs on a cron job.")
2. Therefore the unit of agent infrastructure should be a persistent,
   portable, self-contained artifact (the workbook), not a rented sandbox.
3. Isolation must be free, not rented: BEAM process isolation × wasmtime
   sandboxing on one cheap server vs per-sandbox micro-VM pricing.
4. Heterogeneous tooling makes agent data noise; a homogeneous authoring
   surface makes drift testable, telemetry consistent, and —
   eventually — supervision learnable (the autopoet).
5. The endgame is not better shovels (frameworks); it's living software
   that maintains itself.

## Audience (as spoken, made explicit)

- Enterprise platform/security teams: data sovereignty, China/offshore
  rules, corporate espionage, security review of agent infra. The
  isolation story is FOR them.
- Small teams / solo builders scaling: "start with two people, same system
  scales to a continent"; bill-shock refugees from serverless + micro-VM
  pricing.
- Agent-infra builders: people currently duct-taping Markdown skills,
  vector memory, and rented sandboxes.

## Competitors / contrast objects (as named in the recording)

- Sandbox rental: E2B, Daytona, Firecracker micro-VMs ("a trap" at scale).
- Serverless: Vercel/Cloudflare functions (wrong shape for agents).
- Docker/OCI as the delivery unit (platform-specific, heavyweight).
- StackBlitz WebContainers (closest prior art for in-WASM npm/build;
  browser-bound where we are server+artifact).
- Markdown/skills ecosystems + Letta-style memory (file-based memory
  without testable structure).
- Tauri (platform-agnostic shell — an analogy and a dependency, not a rival).
- "Zero" the agent language (the cautionary tale: a language with no
  project-management spine).
- The Mac-mini-in-the-corner (the absurdist strawman; keep it, it lands).

## Open questions the recording leaves dangling

- What is the actual demonstrated workbook-as-container story vs the pitch?
- Where is the line between "workbook ships its deps like a Docker image"
  and deploy-kit's one-OCI-image model? Two container metaphors in play.
- MCP: explicitly punted ("I haven't really thought about it").
- The model-knowledge benchmark for the config format: cheap to run, never run.
- Drift detection: claimed as the format's killer feature; how much is shipped?
