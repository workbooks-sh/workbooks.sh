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

## Still open

- **rust / zig toolkits** — `Nexus.Toolkit.compile/2` is C-only today; the rust/zig command shapes
  (a normal `main()` linked as a command) are a small lane addition.
- **persistence** — registered toolkits are in-memory per run; a workbook's toolkits compile on
  bring-up. A content-addressed on-disk cache (compile once, reuse) is the natural optimization.
- **arg/usage metadata** — the manifest carries a summary + command names; a richer usage spec
  (flags, examples) would deepen progressive disclosure.
