
# REFERENCE — exhaustive, flat, zero narrative. Each fact carries a :SRC: anchor

> The toolkit authoring surface — manifest schema, EXEC shapes, capability grants, build lanes, and the wbx toolkit CLI. Tangled from code.
# (where truth lives in code) and a :MATURITY: tier. The conceptual "why" lives in
# ../concepts/what-is-a-toolkit.md → links to /learn. Do not narrate here.

# Toolkits

A toolkit is the unit you author, build, and share: a =:toolkit:=-tagged Org node
(the manifest, the front door) + a `SKILL_DIR` of progressive-disclosure recipes +
zero-or-more WASM artifacts (the executable half). The manifest's `#+EXEC` field
selects the artifact's invocation contract; `#+TRUST` the consent posture; `#+CAPS`
the Dock capabilities the artifact may reach (gated by Policy).

- **MATURITY:** ships-today
- **EVIDENCE:** runtime/host/toolkits.ex:1-14
- **SINCE:** 2026-06

Authoritative specs in-repo:
- `runtime/docs/TOOLKIT-MANIFEST.org` — the manifest field list + per-shape requirements (the contract).
- `runtime/docs/TOOLKITS-V3.org` — the system model (discovery, build, security, EXEC modes).
- `toolkits/AUTHORING.org` — the operational skill-authoring depth/breadth standard.

Conceptual orientation (do not duplicate here): [What is a toolkit](../concepts/what-is-a-toolkit.md),
[The six shapes](../concepts/exec-shapes.md), [The Dock & capabilities](../concepts/the-dock.md).

## Manifest fields

One `manifest.org` per toolkit at `toolkits/<name>/manifest.org`. Org keywords
(`#+KEY:`) at file level; some are mirrored into the `:toolkit:` node's
`:PROPERTIES:` drawer (the verifier asserts they match).

- **MATURITY:** ships-today
- **EVIDENCE:** runtime/host/toolkits.ex:487-502
- **SRC:** runtime/host/toolkits.ex#parse_descriptor

Parsed by `parse_descriptor/1` (`toolkits.ex:487`). Discovery reads them via
`kw/2` (file keyword) and `drawer/2` (drawer key) (`toolkits.ex:531-545`).

| Keyword | Meaning | Required for | :SRC: (toolkits.ex) |
| --- | --- | --- | --- |
| `#+TITLE` | human title | all | — |
| `#+TOOLKIT` | slug `= dir name =` `:ID:` (whitespace-free) | all | view/1 :ID: |
| `#+VERSION` | semver of this wrapper | all | — |
| `#+STATUS` | `stable` / `experimental` / `deprecated` | all | view/1 (h.props.STATUS) |
| `#+TAGLINE` | one sentence — when to reach for it | all | injection_text/2 |
| `#+EXEC` | invocation contract (see §EXEC shapes) | built shapes¹ | parse_descriptor :exec |
| `#+TRUST` | `first-party` (default) / `third-party` | all (defaults) | parse_descriptor :trust |
| `#+CAPS` | space-list of Dock caps the artifact may use | non-pure² | parse_descriptor :caps |
| `#+BUILD_LANG` | `rust` / `zig` / `c= / =go` / `js` / `ts` / `svelte` | built shapes | parse_descriptor :build_lang |
| `#+BUILD_SRC` | source spec (see §BUILD_SRC) | built shapes | parse_build_src/1 |
| `#+CLI_BIN` | registered command name (the `run-command` key) | command / posix | parse_descriptor :cli_bin |
| `#+CLI_VERSION_RANGE` | upstream CLI version range the skills assume | command/posix (opt) | — |
| `#+REQUIRES` | extra CLIs/runtimes the skills assume (e.g. `node>=20`) | opt | — |
| `#+ARG_MODE` | `argv` (default) / `stdin1` (first stdin line = arg) | command (opt) | arg_mode/1 (l.523) |
| `#+SHA256` | content hash — for `wasm:` / `archive:` prebuilt fetches | wasm/archive | parse_descriptor :sha256 |
| `#+WASM_PATH` | wasm path inside an `archive:` bundle | archive (opt) | parse_descriptor :wasm_path |
| `#+PREOPEN` | preopened dir for an `archive:` toolkit | archive (opt) | parse_descriptor :preopen |
| `#+AUTHOR_DID` | author `did:key` — provenance for signing | third-party | parse_descriptor :author_did |
| `#+SIGNATURE` | Ed25519 over the canonical manifest (registry tier) | third-party (registry) | parse_descriptor :signature |

¹ A manifest with NO `#+EXEC` is a **discovery-only** toolkit: skills are
discoverable and readable, but there is no built/invoked artifact. The verifier
reports `exec: none declared (discovery-only toolkit)` (`toolkits.ex:950`). Most
shipped toolkits today are discovery-only — their skills are good; their execution
contract is the legacy native-CLI assumption, not yet re-pointed at the clean-room
`command` shape.

- **MATURITY:** partial
- **EVIDENCE:** runtime/host/toolkits.ex:950
- **CAVEAT:** 24 of 27 shipped manifests (e.g. ffmpeg, git, brandnana) declare NO #+EXEC and assume a native PATH binary from the old mainline; only sandbox/* manifests carry a clean-room #+EXEC. Re-pointing is per-toolkit, ongoing (TOOLKITS-V3 §"What exists today").

² "non-pure" = anything reaching a host power. A pure compute+stdio `command`
needs no `#+CAPS`.

### Drawer mirroring

The `:toolkit:` node carries a `:PROPERTIES:` drawer whose `:ID:` / `:CLI_BIN:` /
`:STATUS:` MUST equal the matching `#+` keyword. `CLI_BIN` is read from EITHER the
keyword OR the drawer (`cli_bin: kw(body, "CLI_BIN") || drawer(body, "CLI_BIN")`).

- **MATURITY:** ships-today
- **EVIDENCE:** runtime/host/toolkits.ex:494
- **SRC:** runtime/host/toolkits.ex#parse_descriptor

The discovered view (`view/1`, `toolkits.ex:1073`) exposes exactly: `id`, `title`,
`cli` (`CLI_BIN`), `status`, `skill_dir` (`SKILL_DIR`).

## EXEC shapes

The `#+EXEC` keyword selects the artifact's invocation contract. Six shapes. The
verifier (`exec_checks/1`) recognizes exactly these; any other value fails
`exec: unknown mode` (`toolkits.ex:984`).

- **MATURITY:** partial
- **EVIDENCE:** runtime/host/toolkits.ex:950-984
- **SRC:** runtime/host/toolkits.ex#exec_checks
- **CAVEAT:** command/posix/task/federation are built; component is a substrate (built via build_dir, run in-VM via Instance) with no first-party shipped example; kernel builds only from BUILD_LANG: c today.

| `#+EXEC` | ABI | Consumer | WIT? | Build? | Maturity |
| --- | --- | --- | --- | --- | --- |
| `command` | argv + stdin → stdout + exit | agent, workflow | no | yes | ships-today |
| `posix` | native PATH binary in container | agent, workflow | no | no | ships-today |
| `task` | `:role` bash recipe (`toolkit run`) | agent | no | no | partial (see below) |
| `federation` | OQL data-source + sync daemon | host, OQL | no | mixed | ships-today |
| `component` | WIT-typed, in-process call | component, workflow | yes | yes | partial |
| `kernel` | bytes→bytes, instantiate-once-loop | the fabric | yes | yes | partial |

### command — the stdio leaf (default, most portable)

A CLI compiled to a WASM module. stdio IS the universal API:
`run-command(name, argv, stdin) -> stdout`. Registered in `CommandRegistry` under
`#+CLI_BIN`. Verify: bin registered, OR a buildable `#+BUILD_SRC` (`crate:` /
`path:`) is present (`toolkits.ex:952-962`).

- **MATURITY:** ships-today
- **EVIDENCE:** runtime/host/command_registry.ex:39-64
- **SRC:** runtime/host/instance/imports.ex#run_command

Built-in commands are reserved and cannot be shadowed by a dynamic registration:
`upper`, `jq`, `grep`, `wbox` (`@builtins`, `command_registry.ex:39-64`;
`@reserved`, `l.70`). `register/3` rejects `:reserved_name` (`command_registry.ex:167`).

- **MATURITY:** ships-today
- **EVIDENCE:** runtime/host/command_registry.ex:39-70
- **SRC:** runtime/host/command_registry.ex#builtins

Name charset: `^[A-Za-z0-9_.-]+$` (`@name_re`, `command_registry.ex:79`). Max 4096
dynamic entries (`@max_dynamic`, `l.84`). `ARG_MODE`: `:argv` (default) or `:stdin1`
(first stdin line = arg; `jq` and `grep` use `:stdin1`).

### posix — the native escape hatch

For ffmpeg-class CLIs that don't compile clean to WASI. Runs as a native PATH
binary under the `posix` Policy profile inside the one deploy container. Verify:
`#+CLI_BIN` resolves via `System.find_executable/1` (`toolkits.ex:964-970`).

- **MATURITY:** ships-today
- **EVIDENCE:** runtime/host/toolkits.ex:964-970
- **CAVEAT:** not portable to desktop/browser tiers — only runs inside the deploy container's OS boundary; declare honestly.

### task — recipe-only, no single CLI

Ships `:role task` bash blocks run via `wbx toolkit run <tk> <task> -- …`. Verify
always passes structurally (`toolkits.ex:972`). HOWEVER: native `:role` bash
execution is BANNED (wb-9ja). `exec_allowed?` is hardcoded `false`; `run_bash` is a
no-op (`toolkits.ex:1062`). So a task block does not execute today — ship the CLI
as a WASM `command` instead.

- **MATURITY:** wall
- **EVIDENCE:** runtime/host/toolkits.ex:1062
- **WALL:** bedrock
- **CAVEAT:** the manifest shape is accepted and verify passes, but the executor is disabled by design (no native bash outside WASM). The runnable path is the WASM command shape.

### federation — the three-face SaaS connector

Three wired faces: READ (`SELECT … FROM <entity>` routes to a data-source plugin),
SOURCE (any REST/JSON via `Workbooks.DataSource.Http` with `#+URL/#+ROWS_PATH/#+ENV_KEYS`,
or a custom `query/3` module — Linear/Asana specialize), SYNC (`Workbooks.Plugin.Sync`
mirrors a source into `:task:` nodes on an interval). Verify passes structurally
(`toolkits.ex:973`).

- **MATURITY:** ships-today
- **EVIDENCE:** runtime/host/toolkits.ex:973
- **SRC:** runtime/docs/TOOLKIT-MANIFEST.org#federation
- **CAVEAT:** sync daemons are host-side, never in-wasm; long-lived state is the host's, not the toolkit's.

### component — the typed in-process artifact (absorbs "extension")

A WIT-typed component on `engine.wit` (or a declared `#+WIT` world). Typed I/O
instead of stringly stdio; called in-process via `Instance`, not spawned per call.
A third-party component carries `#+TRUST: third-party` and the deployer grants its
`#+CAPS`. Verify always reports OK structurally (`toolkits.ex:981`).

- **MATURITY:** partial
- **EVIDENCE:** runtime/host/toolkits.ex:981
- **CAVEAT:** substrate exists (build via build_dir, run in-VM via Instance); no first-party shipped component example, and #+WIT/#+ENTRY are spec'd in TOOLKIT-MANIFEST.org but not enforced by parse_descriptor today.

### kernel — the hot-loop artifact (the media/render class)

`bytes → bytes`, instantiated ONCE and called many times in a tight loop. The
fabric owns the loop; the kernel is a pure transform. Verify checks the kernel is
registered in `Workbooks.KernelRegistry` (`toolkits.ex:975-979`). Build supports
ONLY `#+BUILD_LANG: c` today (`package_manager` via `toolkits.ex:836-837`):
"=#+EXEC: kernel — only #+BUILD_LANG: c is supported today=".

- **MATURITY:** partial
- **EVIDENCE:** runtime/host/toolkits.ex:814-837
- **SRC:** runtime/host/toolkits.ex#do_build_clause
- **CAVEAT:** only the C build lane is wired for kernels; Rust/Zig kernel builds are not yet supported.

## TRUST postures

Orthogonal to `#+EXEC`. Governs whether the deployer must consent before the
toolkit's `#+CAPS` are granted. Default `first-party` (`parse_descriptor`,
`toolkits.ex:489`).

- **MATURITY:** partial
- **EVIDENCE:** runtime/host/toolkits.ex:454-461
- **SRC:** runtime/host/toolkits.ex#trust_checks
- **CAVEAT:** trust_checks/2 for third-party asserts #+AUTHOR_DID/#+SIGNATURE presence; the signature-verify + registry sha-pin install path is spec'd (TOOLKIT-MANIFEST.org) but the enforcement is the structural presence check, not a full Ed25519 verify in this lane.

| `#+TRUST` | Consent | Extra fields required |
| --- | --- | --- |
| `first-party` | yours; runs under the profile's default caps; no extra consent | none |
| `third-party` | deployer reviews + grants `#+CAPS` explicitly; sha-pin install | `#+AUTHOR_DID` + `#+SIGNATURE` (registry tier) |

Invariant (both postures, all tiers): an ungranted cap is un-importable, so
un-callable. Trust changes the consent UX, never the enforcement — enforcement is
always the Policy-gated Dock.

- **MATURITY:** ships-today
- **EVIDENCE:** runtime/host/instance/imports.ex:5-12
- **SRC:** runtime/host/instance/imports.ex#for_caps

## Capability grants (`#+CAPS`)

`#+CAPS` is a space-list of Dock capabilities. Each maps to a host import bound by
`Instance.Imports.for_caps/4` (`imports.ex:26`), gated by `Policy`. A component
importing a cap not in the granted profile fails to instantiate.

- **MATURITY:** ships-today
- **EVIDENCE:** runtime/host/instance/imports.ex:26-59
- **SRC:** runtime/host/instance/imports.ex#for_caps

The cap → Dock import bindings actually wired in `imports.ex` (everything else in
the Policy cap set is granted-but-not-bound-here, or bound elsewhere):

| `#+CAPS` name | Dock import bound | host | :SRC: (imports.ex) |
| --- | --- | --- | --- |
| (none) | `session-info` only (always on) | read-only ids | l.27 |
| `vfs` | `vfs-query` | Instance SQLite VFS | l.33-34 |
| `commands` | `run-command` | CommandRegistry (composition) | l.37-38 |
| `llm` | `llm-complete` | Workbooks.Llm (host holds key) | l.41-42 |
| `browse` | `browse-fetch` | Workbooks.Browse (Route B) | l.47-48 |
| `parallel` | `run-command-many` | Workbooks.Fabric (fan-out) | l.56-57 |

An unrecognized cap is a no-op in `for_caps` (`add(_other, …)` returns the acc
unchanged, `imports.ex:59`) — it binds no import, so it grants nothing.

### The full Policy cap set & profiles

`#+CAPS` are validated against the Policy cap universe by `cap_checks/1`
(`toolkits.ex:930-948`): every declared cap must be grantable by SOME profile, and
at least one profile must grant the WHOLE set.

- **MATURITY:** ships-today
- **EVIDENCE:** runtime/host/policy.ex:28-37
- **SRC:** runtime/host/policy.ex#profiles

Profiles (`@profiles`, `policy.ex:28-37`):

| Profile | Memory | Timeout | Caps granted |
| --- | --- | --- | --- |
| `compute` | 64 MiB | 5 s | `vfs` |
| `minimal` | 64 MiB | 5 s | `vfs commands exec kv secrets queue tcp udp tls` |
| `network` | 128 MiB | 30 s | `minimal` + `net llm browse` |
| `posix` | 256 MiB | 60 s | `network` + `posix parallel` |

- **MATURITY:** ships-today
- **EVIDENCE:** runtime/host/policy.ex:28-37
- **SRC:** runtime/host/policy.ex#profiles

Fail-closed: an unknown/typo'd profile resolves to `compute` (vfs-only), NEVER the
broader `minimal` (`fetch/1`, `policy.ex:71`). High-level network (`wasi:http` +
`inherit_network` + DNS) is gated by `allow_http?/1` — true ONLY if the profile
grants `net` or `browse` (`policy.ex:64-67`). `minimal` grants raw-socket caps
(`tcp/udp/tls`) but NOT `wasi:http` egress.

- **MATURITY:** ships-today
- **EVIDENCE:** runtime/host/policy.ex:64-71
- **SRC:** runtime/host/policy.ex#allow_http?

Caps in the Policy universe but NOT bound as a Dock import in `imports.ex`
(`exec kv secrets queue tcp udp tls posix`): granted by profile, enforced/bound by
other host seams — not the `for_caps` component-import surface. `frames` (the
shared-frame arena for kernels) is **proposed**, not in the Policy set today.

- **MATURITY:** north-star
- **CAVEAT:** the `frames` zero-recopy cap for the media/kernel class is proposed (wb-rhs.5/.9), not in policy.ex; do not assume it.
- **SINCE:** planned

## BUILD_SRC — source specs

`#+BUILD_SRC` is parsed into a tagged tuple by `parse_build_src/1`
(`toolkits.ex:507-521`). Recognized prefixes:

- **MATURITY:** partial
- **EVIDENCE:** runtime/host/toolkits.ex:507-521
- **SRC:** runtime/host/toolkits.ex#parse_build_src
- **CAVEAT:** crate:/path:/wasm:/archive: build through `wbx toolkit build`; git+ is parsed but NOT yet supported by build (returns an error, toolkits.ex:891); gobuild:/script:/zigbuild: are parsed but script: is removed (wb-9ja).

| Prefix | Tuple | Build support | :SRC: (toolkits.ex) |
| --- | --- | --- | --- |
| `crate:<n>` | `{:crate, n}` | yes — build_and_register_crate (mrustc→clang in sandbox) | do_build_clause l.786 |
| `path:<dir>` | `{:path, dir}` | yes — PackageManager.build_dir + register | do_build_clause l.790 |
| `wasm:<url>` | `{:wasm, url}` | yes — fetch prebuilt wasm (`#+SHA256` pinned) | do_build_clause l.842 |
| `archive:<url>` | `{:archive, url}` | yes — fetch + extract bundle (`#+WASM_PATH/#+PREOPEN`) | do_build_clause l.858 |
| `git+<url>` | `{:git, url}` | NOT yet — "use crate: or path:" | do_build_clause l.891 |
| `gobuild:<pkg>` | `{:gobuild, p}` | go build lane | do_build_clause l.876 |
| `zigbuild:<rel>` | `{:zigbuild, r}` | zig build lane | do_build_clause l.880 |
| `script:<rel>` | `{:script, rel}` | REMOVED (wb-9ja) — native build scripts banned | do_build_clause l.884 |
| (other) | `{:unknown, s}` | error — unrecognized | do_build_clause l.894 |

## Build lanes (`#+BUILD_LANG`)

Every untrusted-source lane compiles ENTIRELY in the WASM sandbox — zero native
execution. `PackageManager.build_dir/2` dispatches by lang.

- **MATURITY:** ships-today
- **EVIDENCE:** runtime/host/package_manager.ex:152-306
- **SRC:** runtime/host/package_manager.ex#build_dir

| `#+BUILD_LANG` | In-sandbox lane | :SRC: (package_manager.ex) |
| --- | --- | --- |
| `rust` | mrustc.wasm → clang.wasm + std (pure-crate deps via dep pipeline) | build_dir l.152 |
| `c=            \| clang.wasm (all =*.c` under dir) | build_dir l.223 / build_c_dir l.230 |  |
| `zig` | zig1.wasm (.zig→C) → clang.wasm | build_dir l.277 |
| `go` / `tinygo` | go-yaegi / tinygo lane | build_dir l.197 |
| `js` / `ts` | bundlejob → Javy → wasm (ts: tsc-in-QuickJS first) | build_dir l.177 |
| `svelte` | svelte compile in qjs-run.wasm → bundle → JS lane | build_dir l.296 |
| (other) | `{:error, {:unsupported_dir_lang, lang}}` | build_dir l.306 |

- **MATURITY:** partial
- **EVIDENCE:** runtime/host/package_manager.ex:147-165
- **CAVEAT:** Rust pure-crate deps resolve in-sandbox; proc-macro / codegen-heavy crates do not (FORGE limit). Build cost gates the real-time path: JS (Javy) / Zig build mid-session; Rust (mrustc) is the build-deploy lane.
- **SINCE:** 2026-06

Lane canon: untrusted source NEVER compiles or runs natively. Native tools that
remain (`wac` for component compose) only operate on already-built, validated
TRUSTED components — not on untrusted source (`package_manager.ex:6-31`).

- **MATURITY:** ships-today
- **EVIDENCE:** runtime/host/package_manager.ex:6-31
- **WALL:** forge

## The `wbx toolkit` CLI

The learn/build/run surface. Verbs (`ToolkitVerb`, `cli/src/main.rs:145-172`);
dispatch at `main.rs:326-336`.

- **MATURITY:** ships-today
- **EVIDENCE:** cli/src/main.rs:145-172
- **SRC:** cli/src/main.rs#ToolkitVerb

| Command | Does | :SRC: (main.rs) |
| --- | --- | --- |
| `wbx toolkit list` | list discoverable toolkits (id · status · tagline) | l.327 |
| `wbx toolkit show <id> [skill]` | manifest + skill index, or one skill's recipe | l.328 |
| `wbx toolkit search <q>` | substring match across toolkits + skills | l.329 |
| `wbx toolkit verify <id>` | structural + cap + trust + exec contract checks | l.330 |
| `wbx toolkit sign <id>` | sign a manifest (`did:key` provenance; req. third-party) | l.331 |
| `wbx toolkit build <id> [which]` | in-sandbox compile + register the declared artifact | l.332 |
| `wbx toolkit push <id> <dir>` | ship a toolkit dir onto the engine (deploy-the-toolkit) | l.333 |
| `wbx toolkit import <source> [--as] [-o]` | package a Claude skill / markdown / folder as a toolkit | l.334 |
| `wbx toolkit audit <dir> [--fix]` | re-run the wasm-compatibility audit on an imported dir | l.335 |
| `wbx toolkit run <id> <task> -- <args>` | run a `:role task` recipe (gated: `WB_TOOLKIT_EXEC=1`) | l.336 |

- **MATURITY:** partial
- **EVIDENCE:** runtime/host/toolkits.ex:1062
- **CAVEAT:** `toolkit run` requires WB_TOOLKIT_EXEC=1 AND a non-native executor; native :role bash is disabled (wb-9ja), so run only fires for WASM-backed recipes, not arbitrary host bash.

The engine-side implementations these verbs call: `Workbooks.Toolkits.list_text`,
`show_text`, `show_skill_text`, `search_text`, `verify_text`, `build_text`,
`eval_text`, `run` (`toolkits.ex:116-360`).

### What `verify` checks

`verify_text/2` (`toolkits.ex:228`) emits ✓/✗ for: `manifest.org` present;
`skills/overview.org` present; per-EXEC contract (`exec_checks`); cap grantability
(`cap_checks`); third-party trust fields (`trust_checks`). `:role` pre blocks are
reported DISABLED, never run (native exec banned, `toolkits.ex:252-254`).

- **MATURITY:** ships-today
- **EVIDENCE:** runtime/host/toolkits.ex:228-256
- **SRC:** runtime/host/toolkits.ex#verify_text

## Discovery

One query: `(tags :toolkit:)` over the Context Tree (`toolkits.ex:41-43`). On
disk: read every `<root>/<name>/manifest.org` (`discover_dir`, `toolkits.ex:47-58`).
An `:agent:` node's `:TOOLKITS:` property lists the toolkits it may use, resolved
in declared order; unknown names are dropped, never a crash (`for_agent`,
`toolkits.ex:68-74`).

- **MATURITY:** ships-today
- **EVIDENCE:** runtime/host/toolkits.ex:41-74
- **SRC:** runtime/host/toolkits.ex#discover

Discovery root: `$WB_TOOLKITS_ROOT` (honored ONLY if it names an existing dir —
wb-sec finding #6), else first of `toolkits/` | `../toolkits` that exists
(`default_root`, `toolkits.ex:108-113`). The root is an UNAUTHENTICATED, writable
dir → toolkits there are untrusted supply-chain input; read surfaces are open,
EXECUTION (verify pre / run / build) is separately gated (`toolkits.ex:19-37`).

- **MATURITY:** ships-today
- **EVIDENCE:** runtime/host/toolkits.ex:19-37
- **SRC:** runtime/host/toolkits.ex#default_root

## Skills (progressive disclosure)

The manifest is the INDEX; skills are read on demand. The auto-injected agent
prompt carries one line per declared toolkit + up to 8 skill names
(`injection_text/2`, `toolkits.ex:138-175`). The agent then reads a skill body via
`wbx toolkit show <id> <skill>`. The runtime resolves **which** toolkit; it never
inlines the manual.

- **MATURITY:** ships-today
- **EVIDENCE:** runtime/host/toolkits.ex:138-201
- **SRC:** runtime/host/toolkits.ex#injection_text

Slug safety: a skill slug must match `^[A-Za-z0-9._-]+$` and resolve strictly
inside `<dir>/skills/` — no `..`, no separators, no symlink escape (`@slug_re` +
`contained?`, `toolkits.ex:1018-1030`).

The depth/breadth authoring standard (mandatory skill sections, the task tier, the
overview.org requirement, the consistency contract) lives in `toolkits/AUTHORING.org`
— see [Author a toolkit](../build/author-a-toolkit.md) for the how-to.

- **MATURITY:** ships-today
- **EVIDENCE:** toolkits/AUTHORING.org:37-101
- **SRC:** toolkits/AUTHORING.org#manifest

## Limits (the structural walls)

What a toolkit artifact CANNOT be, per the runtime limits (`TOOLKIT-MANIFEST.org`
§"What can and cannot be a toolkit"):

- **MATURITY:** wall
- **EVIDENCE:** runtime/docs/TOOLKIT-MANIFEST.org:1-300
- **WALL:** bedrock
- **CAVEAT:** real-time HD inter-frame encode (single-thread WASM CPU); GPU compute (no path, CPU-first by design); working sets >256 MiB (memory cap, no memory64); native-thread parallelism inside one kernel (parallelism is fabric fan-out); persistent daemons / raw sockets in-wasm (long-lived sync is federation host-side; egress is host-mediated browse/net).

The pattern: stateless, bounded, single-shot or hot-loop transforms thrive;
long-lived / threaded / huge-memory / GPU workloads do not.

## See also

- [Concept: what is a toolkit](../concepts/what-is-a-toolkit.md) → links to the /learn deep page.
- [Reference: #+EXEC shapes](exec-shapes.md) · [Reference: Dock capabilities](caps.md) · [Reference: manifest fields](manifest.md)
- [How-to: author a toolkit](../build/author-a-toolkit.md)
- Truth in code: `runtime/host/toolkits.ex` · `command_registry.ex` · `instance/imports.ex` · `policy.ex` · `package_manager.ex` · `cli/src/main.rs` (`ToolkitVerb`).
- Authoritative specs: `runtime/docs/TOOLKIT-MANIFEST.org` · `runtime/docs/TOOLKITS-V3.org` · `toolkits/AUTHORING.org`.
