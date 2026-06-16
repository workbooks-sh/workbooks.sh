# Toolkits V3 — Finish + Hardening Report

*2026-06-07*

# Scope

  Final verification of the toolkits-finish branch against the design of record
  (TOOLKITS-V3.md). This report records, for each declared gap, an honest
  DONE/PARTIAL/BLOCKED verdict with a reproducible proof (test name / command),
  the full test-suite result, the security-finding ledger, and an explicit
  no-stubs attestation.

  Verification commands (run in runtime/, 2026-06-07):
  - `mix compile` → clean, no warnings-as-errors, no output.
  - `mix test` → 226 tests, 2 failures (both intentional known-bug markers; see §2).
  - `mix test --only build` → 36 build-tagged tests, 0 failures (cargo/go/js/zig
    toolchain paths; crate artifacts content-addressed + cached in build/commands/).

# 1. Gap ledger

| Gap | Verdict | Proof |
| --- | --- | --- |
| P4 declarative (#+EXEC/...) | DONE | test/toolkit_build_test.exs (7 tests, 0 fail) |
| P5 build recipes (go/js/..) | DONE | test/build_recipes_test.exs (8 tests, 0 fail) |
| P10 mmap shim | DONE | build_recipes_test.exs "mmap shim round-trips a file" |
| P2 telemetry (run-command) | DONE | test/run_command_telemetry_test.exs (2 tests, 0 fail) |
| P6 browse-fetch Dock import | DONE | test/browse_dock_test.exs (5 tests, 0 fail) |

## P4 — Declarative EXEC / build descriptor — DONE

   `Workbooks.Toolkits.parse_descriptor/1` + `descriptor/1` parse
   `#+EXEC / #+BUILD_SRC / #+BUILD_LANG / #+CAPS` from a toolkit manifest;
   `wb toolkit build` drives the build per declared lang and refuses a CLI_BIN
   that collides with a reserved built-in.
   Proof (all in test/toolkit_build_test.exs, 0 failures):
   - "parse_descriptor reads #+EXEC / #+BUILD_SRC / #+BUILD_LANG / #+CAPS"
   - "parse_descriptor: empty keyword is nil, not the next line" (regression on a
     real org-parse footgun — a blank `#+EXEC:` must NOT swallow the next line)
   - "parse_descriptor recognizes git+ and path: build sources"
   - "verify reports the #+EXEC: command is satisfiable via the build descriptor"
   - "wb toolkit build refuses a reserved CLI_BIN (no shadowing of jq)"
   - "wb toolkit build huniq compiles the crate, registers it, and it runs"
     (@tag :build — real `cargo install huniq --target wasm32-wasip1`, end-to-end
     through CommandRegistry; verified under `mix test --only build`).

## P5 — CLI→WASM build recipes (rust/go/js + zig/c) — DONE

   `PackageManager.build_dir/2` covers go (=GOOS=wasip1=), js (Javy/bun), zig/c,
   and rust; outputs are content-addressed into build/commands/ and registered.
   `--help` capture seeds drafts. Proof (test/build_recipes_test.exs, 0 failures):
   - "build_dir Go fixture -> runnable wasip1 command (argv + stdin)"
   - "build_dir JS fixture -> runnable command (stdin -> stdout)"
   - "content_address is idempotent and lands in build/commands"
   - "register_artifact content-addresses then registers a runnable command"
   - "capture_help on huniq" / "capture_help on sd" (@tag :build — real crates).
   HONEST SCOPE (carried from TOOLKITS-V3 §"HONEST SCOPE"): auto-wrap covers
   WASI-clean compute+stdio CLIs. Native-C / threads / GPU CLIs still take
   `#+EXEC: posix`. Not regressed; this is the designed boundary, not a gap.

## P10 — mmap emulation shim — DONE

   build/shims/mmap_shim.c (file-backed mmap over pread/pwrite; MAP_PRIVATE via
   malloc+pread, MAP_SHARED flush on msync/munmap via pwrite) is link-injected
   into every C/wasi build by PackageManager, redirected via `wasm-ld --wrap`
   (two-phase: zig cc -v to capture the real link line, replay through wasm-ld
   with --wrap injected — sysroot paths read from zig's cache, never hardcoded).
   Proof (test/build_recipes_test.exs, 0 failures):
   - "build_dir C fixture: mmap shim round-trips a file (read + MAP_SHARED
     write-back)" — a C CLI mmaps MAP_SHARED, reads through the pointer and
     writes back to the host file via a wasmtime preopen, CLI source untouched.
   - "build_dir C: without a preopen the guest cannot reach the host file
     (isolation)" — confirms the preopen is the only bridge (NotFound otherwise).
   RESIDUAL (documented, not a defect): no lazy demand-paging (huge >4GB files)
   and no cross-process shared-memory IPC → those remain `#+EXEC: posix`. Rust
   memmap2 hard-gates on cfg before any FFI call, so it needs a patched fork, not
   the link shim (the C/zig path links directly). Both documented in TOOLKITS-V3.

## P2 — run-command telemetry — DONE

   The `run-command` Dock closure (instance/imports.ex) now carries workdir
   context and appends a step to `_steps.jsonl` per call, in the same shape
   agent.ex/log_step writes and counted by workflow/telemetry.ex summary/1.
   Proof (test/run_command_telemetry_test.exs, 0 failures):
   - "run-command Dock call emits a workdir-scoped step that summary/1 counts"
   - "with no workdir the closure runs but writes no step" (no global side effect
     when unscoped — correct, not a silent drop).

## P6 — browse-fetch Dock import — DONE

   `browse-fetch` added to the Dock (instance/imports.ex, engine.wit), bound to
   `Workbooks.Browse.fetch`, gated by the `browse`/`net` Policy cap (Route B —
   the guest never holds a socket; host owns egress/creds). Proof
   (test/browse_dock_test.exs, 0 failures):
   - "policy: browse cap is granted by network/posix, denied by minimal"
   - "the browse Dock closure reaches Workbooks.Browse and returns the extracted page"
   - "the engine-browse-probe component fetches a URL through the Dock end to end"
     (real prebuilt WASM that hard-imports browse-fetch, driven through for_caps)
   - "a minimal-profile Instance cannot instantiate the browse component (cap
     enforced)" — negative proof the gate actually denies.

# 2. Test suite

  - Total: 226 tests (default `mix test`). 224 passing, 2 failing.
  - Plus 36 `@tag :build` tests, 0 failing (run via `mix test --only build`;
    real cargo/go/js/zig compiles; crate artifacts cached content-addressed).
  - Compile: clean.

  Both failures are INTENTIONAL "known-bug" markers left by prior work to keep a
  real defect visible. Each is a genuine bug in a builtin/helper, NOT in the
  finish-branch features. They are called out here, not hidden:

## FAILING #1 — toolkits_test.exs:190 "renders a thin skill body with a CAPTION TOC header"

   REAL BUG (unfixed). `Toolkits` CAPTION extraction (host/toolkits.ex:495) uses
   `~r/^#\+CAPTION:\s*(.+)$/m` — anchored to column 0, no leading-whitespace
   tolerance. Every authored git skill INDENTS its `#+CAPTION` lines, so the
   `show <tk> <skill>` TOC header ("TOC (CAPTIONs):") is NEVER emitted for the
   real tree. A companion test (toolkits_test.exs:202) documents the blast radius:
   all 9 git skills carry captions, none render a TOC. Fix is one line — allow
   leading whitespace: `~r/^[^\S\n]**#\+CAPTION:[^\S\n]**(.+)$/m` (matching how the
   kw/drawer regexes already tolerate indentation). Left failing by design to
   keep the defect visible; not in this branch's task scope to silently flip.

## FAILING #2 — command_registry_test.exs:452 "very-long stdin (256 KiB) round-trips through upper"

   REAL BUG (unfixed). The `upper` builtin's JS (host/command_registry.ex:35)
   reads into a FIXED 8192-byte buffer: =const b=new Uint8Array(8192); ...
   readSync(0,b.subarray(t))=. Once `t` reaches 8192, `subarray(8192)` is empty,
   `readSync` returns 0, the loop exits — so ANY stdin over 8 KiB is SILENTLY
   TRUNCATED to its first 8192 bytes (measured: 256 KiB in → 8192 bytes out).
   This is a correctness/data-loss bug in the demo builtin. Fix belongs in the
   JS (grow/chunk the buffer until readSync returns 0), not the test. `jq` and
   `grep` are real prebuilt WASM and are unaffected; `upper` is the Javy demo
   builtin. Left failing by design as the correct expectation.

  Assessment: neither failure regresses a finish-branch feature; both are
  pre-existing defects in unrelated demo/helper code, deliberately surfaced.
  Recommend a one-line fix for each before shipping the `wb toolkit show` TOC and
  before promoting `upper` beyond a demo. Not silently patched here to respect
  the "do not hide a failing test exposing a real bug" rule.

# 3. Security audit (wb-sec)

  All findings below were confirmed against the code (not just the doc). "Fixed?"
  reflects what is actually in the source on this branch.

| # | Sev | Finding | Status |
| --- | --- | --- | --- |
| 1 | HIGH | wasi:http egress ungated — every Instance (incl minimal) | FIXED. allow_http? derived |
|  |  | reached host network regardless of caps | from caps (policy.ex:46); |
|  |  |  | gates wasi:http+inherit_network |
|  |  |  | +DNS. test/policy_network 0 fail |
| 2 | HIGH | toolkit skill slug path traversal (../, separators) | FIXED. contained?/2 |
|  |  |  | (toolkits.ex:479) canon+assert |
|  |  |  | under <tk>_skills_ |
| 3 | HIGH | :role bash from a discovered (untrusted) toolkit ran as | FIXED. default-deny; |
|  |  | bare host code on verify/run | WB_TOOLKIT_EXEC=1 opt-in + |
|  |  |  | Sandbox.run + ulimit prologue |
|  |  |  | (toolkits.ex:528-537) |
| 4 | HIGH | build/compile shelled to host directly (doc claimed | FIXED. all compiler invocations |
|  |  | sandboxed) — network + fs ambient at build time | route through Sandbox.run / |
|  |  |  | run_net; cargo build --offline |
| 5 | MED | cargo install option-injection (--git=<url> as crate name) | FIXED. "--" before crate spec |
|  |  |  | + charset guard on crate token |
|  |  |  | (command_registry.ex:157,200) |
| 6 | MED | reserved built-ins (jq/grep/upper) shadowable by dynamic | FIXED. @builtins merged LAST |
|  |  | registry → lookup hijack | (registry/0:77); register/3 |
|  |  |  | rejects reserved names |
| 7 | MED | register→run TOCTOU on content-addressed artifact | FIXED. sha256 re-hashed at RUN |
|  |  |  | time, mismatch refused |
|  |  |  | (command_registry.ex:269-279) |
| 8 | MED | register/3 accepted arbitrary wasm path / empty names | FIXED. path must resolve inside |
|  |  |  | build/commands/; name charset |
|  |  |  | guard (command_registry.ex:85+) |
| 9 | MED | infinite-loop / oversized guest could hang/OOM host | FIXED. wasmtime -W timeout + -W |
|  |  | (Policy CPU cap never wrapped the run path) | fuel; @max_input 64MiB / |
|  |  |  | @max_argv 256KiB caps |
|  |  |  | (package_manager.ex:39-43,464) |
| 10 | MED | WB_TOOLKITS_ROOT could repoint surfaces to attacker dir | FIXED. honored only if an |
|  |  | (blank/bogus value) | existing dir (toolkits.ex) |
| 11 | LOW | dynamic registry unbounded growth (registration storm) | FIXED. @max_dynamic 4096 cap |
|  |  |  | (command_registry.ex:67,111) |

  RESIDUAL RISK (honest — NOT fixed on this branch, by design / out of reach):

  - R1 (from #1 tail) — Stock wasmex `add_to_linker_sync` still links the full
    wasi:p2 TYPE surface (clocks/random/filesystem-types/cli-environment) into
    EVERY component unconditionally. Wall-clock + CSPRNG remain AMBIENT even on
    `minimal`. The exploitable hole (network egress) is closed; clocks/random are
    low-harm ambient caps. Removing them needs a custom per-profile linker /
    restricted WasiCtx in the wasmex NIF (or an import-allowlist validation pass).
    That NIF-level change is NOT done here.

  - R2 (cargo-install supply chain) — `cargo install <crate>` MUST reach the
    registry, so it runs FS-confined but network-PERMITTED (Sandbox.run_net). A
    fetched crate's build.rs / proc-macros execute with network during install.
    Installing an arbitrary published crate is an inherent trust decision —
    mitigate by allowlisting/reviewing crate names. The fully offline,
    network-denied path is source-dir builds (build_dir).

  - R3 (registry isolation) — the dynamic registry is a single process-wide
    :persistent_term. Registration is now name/path-guarded and size-bounded, but
    it is NOT per-Instance/per-tenant namespaced and registration is not gated by
    a Policy capability. Cross-tenant poisoning of NON-reserved command names by
    code that can call register/3 remains possible. Reserved built-ins cannot be
    poisoned (#6). Full isolation needs a per-session registry struct threaded
    through run/ — tracked as a follow-up refactor.

  Severity note: R1 and R3 are the two real residuals an operator must accept (or
  schedule). Neither is a silent claim — both are documented in TOOLKITS-V3.md
  §"Security model" and surface here for visibility.

# 4. Stub / mock attestation

  NOTHING in the toolkits-finish surface (command_registry.ex, package_manager.ex,
  shell.ex, toolkits.ex, instance/imports.ex, engine.wit, cli.ex) is stubbed,
  mocked, or returns fake success. Verified by grep across host/ + wit/:

  - All `TODO` hits are org-mode TASK KEYWORDS (the Workflow.Todo interpreter,
    web.ex TODO outline route, demos/kernel.ex roadmap), NOT code stubs.
  - All `placeholder` hits are the SECRET feature `{{secret:NAME}}` masking
    (secret.ex / vars.ex) — a real mechanism, not a stand-in.
  - host/build.ex (the older Workbook builder, out of finish scope) is honest:
    a missing toolchain yields an `unbuilt` entry WITH A REASON, never a fake
    artifact (build.ex:81-123). That is a real failure path, not a stub.
  - telemetry/wasm_bridge.ex notes a guest-side transform tool as an honest TODO
    at the boundary; the bridge itself is complete. Out of finish scope.

  The two failing tests (§2) are the opposite of stubs: real expectations left
  asserting the correct behavior so genuine bugs stay visible.

# Conclusion

  All five declared gaps (P4, P5, P10, P2, P6) are DONE with passing, real
  (non-mocked) tests, including crate/go/js/zig compiles end-to-end. Eleven
  security findings are fixed in source and proven; three residual risks (ambient
  wasi clocks/random, cargo-install supply chain, process-wide registry) are
  documented, not hidden. Two pre-existing real bugs (indented-CAPTION TOC,
  upper 8KiB stdin truncation) remain, surfaced by deliberately-failing tests —
  each a one-line fix, called out rather than patched silently.
