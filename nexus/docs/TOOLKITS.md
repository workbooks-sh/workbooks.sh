# Toolkits

A **toolkit is a wrapped CLI** — a `wasm32-wasi` command module (`main()` reading argv/stdin, writing
stdout, exactly like `coreutils.wasm`). It's the unit of capability an agent uses: the agent has one
tool, `bash`, and everything it can *do* is a toolkit run through bash. There are no discrete "tools".

## Three ways to get a toolkit

### 1. Author it in a `.work` file (the dogfooding path)

A `toolkit` unit is a literate function — a peer of `agent` / `resource` / `rust`. The body is a CLI;
the same compiler that builds units compiles it to a WASI command module and registers it:

```
toolkit :upper do
  // summary: uppercase stdin
  #include <stdio.h>
  #include <ctype.h>
  int main(void) { int c; while ((c=getchar())!=EOF) putchar(toupper(c)); return 0; }
end
```

`Nexus.Compile.unit` on this → `{:toolkit, {:ok, "upper"}}` (compiled + registered). It's then in the
kit catalog (`upper — uppercase stdin`) and any agent can run it in bash: `cat in.txt | upper`. A
`// summary:` (or `# summary:`) comment becomes the catalog line. Default language is **C** (the
natural CLI language and our command lane); `lang:` selects others as their command lanes land.

### 2. Drop a prebuilt `.wasm` into the kits dir (file registration)

Put `<name>.wasm` (any `wasm32-wasi` command) in the kits dir (`config :nexus, kits_root`, default
`nexus/kits/`). Add an optional plain-text manifest `<name>.kit` for progressive disclosure:

```
a jq-style JSON processor      ← line 1: the catalog summary
jq filter map select           ← line 2: the commands it provides (shown by `help <name>`)
```

`coreutils.wasm` is the built-in core kit (the whole unix base as one multicall module).

### 3. Register one in-memory (programmatic)

```elixir
Nexus.Agent.Kits.register("demo", "/path/demo.wasm", summary: "a demo", commands: ["demo"])
```

`Nexus.Toolkit.build/1` uses this after compiling a `toolkit` unit.

## The interface

| Function | Purpose |
|---|---|
| `Nexus.Agent.Kits.all/0` | every kit: `%{name => %{wasm, summary, commands}}` (core + file + in-memory) |
| `Kits.summary/0` | the one-line catalog for the agent's system prompt (progressive disclosure L1) |
| `Kits.help/1` | a kit's commands (progressive disclosure L2 — `help <kit>` in bash) |
| `Kits.resolve/1` | a command name → `{wasm, leading_args}` (how bash finds the wasm to run) |
| `Kits.register/3` | register an in-memory kit; `clear_registered/0` to drop |
| `Nexus.Toolkit.build/1` | compile + register a `toolkit` unit |
| `Nexus.Toolkit.compile/2` | a toolkit's source → a WASI command module |

## How it runs

The agent calls a toolkit by name in `bash`; `Kits.resolve` maps it to the wasm; `Agent.Bash` runs
`wasmtime run <wasm> <argv> < stdin` against the agent's `/work` VFS (sandboxed — the toolkit sees
only `/work`, runs as wasm, never native code), with a per-command timeout. Toolkits compose with
pipes and coreutils (`cat data | upper | sort`).

## The shape detail (why two compile outputs)

The compile lanes emit two wasm shapes:
- **reactor / component** (`--no-entry --export`) — for `resource`/render units (WIT exports).
- **command** (`crt1-command.o` + libc, a `main()`) — for **toolkits** (argv/stdin/stdout CLIs).

`Nexus.Compilers.C.compile_to_wasm(src, shape: :command)` produces the command shape. Toolkits use it.

## Languages — `Nexus.Lang` / `Nexus.Langs` (the explicit set)

The WebAssembly compiler languages are not loose modules — they're an explicit, registered set behind
the **`Nexus.Lang`** behaviour, listed by **`Nexus.Langs`**. (A *language* is how source becomes wasm;
do not confuse it with a *toolkit*, which is a wrapped CLI an agent runs.) Each language declares its
`id` (the unit `lang`), its output `shapes` (`:command` for CLIs/toolkits, `:component` for
resource/render units), and compiles source.

```elixir
Nexus.Langs.ids()                      #=> ["c", "rust", "zig"]
Nexus.Langs.supports?("rust", :command) #=> true
Nexus.Langs.catalog()                  # one line per language + shapes + summary
```

**To add a WebAssembly compiler language:** implement `Nexus.Lang` (`id/0`, `summary/0`, `shapes/0`,
`compile/3`) and call `Nexus.Langs.register/1`. It's then available to toolkits (and the unit lanes)
automatically — the whole extension surface, no orchestrator edits.

A toolkit is just the **`:command`-shape output** of a language. The languages differ in how naturally
they produce one:

- **`c` / `cpp`** — link `crt1-command.o` + libc (the `:command` shape). A normal `int main()`.
- **`rust`** — the *simplest*: the rust lane already links `crt1-command.o`, so a plain `fn main()`
  program **is** a command module — no exports / keep-alive (that was the extra for the component
  model). `lang: "rust"` (or just write `fn main`).
- **`zig`** — **not** just-the-command-output. Our zig path (`zig1 build-obj -ofmt=c`, the bootstrap C
  backend) is **exports-shaped** and can't lower a full `pub fn main()` std-I/O program to a command
  (it's why the zig *unit* lane only does `export fn`). A zig CLI toolkit needs a C-main shim calling
  a zig export, or zig's self-hosted exe backend — a real follow-up. **Author CLI toolkits in `rust`
  or `c` today.**

Language is taken from `lang: <x>` in the header, else inferred from the body (`fn main` → rust,
`pub fn main` → zig, else C).

## Still open

- **zig command toolkits** — the exports→command shim (above).
- **persistence** — registered toolkits are in-memory per run; a workbook's toolkits compile on
  bring-up. A content-addressed on-disk cache (compile once, reuse) is the natural optimization.
- **arg/usage metadata** — the manifest carries a summary + command names; a richer usage spec
  (flags, examples) would deepen progressive disclosure.
