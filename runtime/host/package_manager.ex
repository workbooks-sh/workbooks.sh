defmodule Workbooks.PackageManager do
  @moduledoc """
  Tangle: take the OQL build plan from a literate Workbook and compile each
  component's source block to a WASM component, content-addressed in build/cache.

  Isolation — the only place we run OS processes. The whole runtime is wrapped in
  ONE portable Linux container (OCI/Docker — local now for deployment isolation,
  the same image in cloud), so the app is always on Linux. NOT a microVM, and NOT
  per-component — one outer container for the whole runtime; workbooks/commands are
  WASM-in-BEAM inside it. `bwrap` then does cheap per-build namespace isolation
  INSIDE that container — one outer container, many bwrap jobs, no per-build or
  per-session sandboxes at the OS level. The build isolator is
  `Workbooks.Sandbox` (bwrap on Linux, sandbox-exec locally); untrusted
  user-submitted source compiles under it (network-denied) once deps are
  pre-fetched (wb-11ck.36). The compile commands below run the trusted toolchain.
  """

  @tools Path.expand(Path.join([__DIR__, "..", "build", "tools"]))
  @javy Path.join(@tools, "javy")
  @wasm_tools Path.join(@tools, "wasm-tools")
  @wac Path.join(@tools, "wac")
  # jco/componentize-js (node_modules/.bin) — the ONLY path that emits a real
  # WIT-typed component from JS. `bun install` in runtime/ provisions it.
  @jco Path.expand(Path.join([__DIR__, "..", "node_modules", ".bin", "jco"]))
  # Javy emits a CORE command module (exports `_start`) → use the command adapter:
  # it both validates AND runs under wasmtime. The reactor adapter yields an
  # export-less component that can be neither run nor composed (see COMPOSE-NOTES.org).
  @adapter Path.join(@tools, "wasi_snapshot_preview1.command.wasm")
  @cache Path.expand(Path.join([__DIR__, "..", "build", "cache"]))
  # Content-addressed store for registered command artifacts: a built .wasm is
  # hashed (sha256 of its bytes) and copied here as <sha>.wasm. Same source ⇒ same
  # hash ⇒ same path ⇒ idempotent rebuilds (no duplicate artifacts, stable id).
  @commands Path.expand(Path.join([__DIR__, "..", "build", "commands"]))

  @doc "Tangle a literate Workbook: build every component → [{name, lang, result}]."
  def tangle(org) when is_binary(org) do
    Workbooks.OQL.tangle_plan(org)
    |> Map.get("worlds", [])
    |> Enum.flat_map(&components/1)
    |> Enum.map(&build/1)
  end

  defp components(%{"components" => comps} = w),
    do: comps ++ Enum.flat_map(Map.get(w, "workflows", []), &components/1)

  @doc """
  Build one component. Two modes: a `:dir` reference builds a REAL project
  directory with its own manifest (Mode 2); otherwise the inline source block is
  compiled, content-addressed (Mode 1). Returns {name, lang, result}.
  """
  def build(%{"name" => name, "lang" => lang} = comp) do
    result =
      if dir = comp["dir"],
        do: build_dir(dir, lang),
        else: build_inline(lang, comp["src"], comp["deps"] || [])

    {name, lang, result}
  end

  defp build_inline(lang, src, deps) do
    out = Path.join(@cache, "#{cache_key([lang, src, Enum.join(deps, ",")])}.wasm")
    if File.exists?(out), do: {:ok, out, :cached}, else: compile(lang, src, out)
  end

  @doc """
  Mode 2 — build a component from a REAL project directory. The dir owns its
  Cargo.toml / package.json; its dependencies are defined THERE, not in Org. We
  just run the native toolchain. (Path is relative to the runtime app dir.)

  Component-aware: a crate that declares `[package.metadata.component]` (it
  targets a WIT world, e.g. `workbooks:engine`) is built with `cargo component`
  into a real Component — the path a Workbook takes. A plain crate stays a
  core module (the tool path).
  """
  def build_dir(dir, "rust") do
    abs = Path.expand(dir)
    manifest = Path.join(abs, "Cargo.toml")
    {tool, lead} = if component_crate?(manifest), do: {"cargo-component", ["component"]}, else: {"cargo", []}
    cmd = lead ++ ["build", "--manifest-path", manifest, "--target", "wasm32-wasip1", "--release"]

    case System.cmd(tool_bin(tool), cmd, stderr_to_stdout: true, env: cargo_env()) do
      {_, 0} ->
        case Path.wildcard(Path.join([abs, "target", "wasm32-wasip1", "release", "*.wasm"])) do
          [wasm | _] -> {:ok, wasm, if(lead == [], do: :built_dir, else: :built_component)}
          [] -> {:error, "no wasm produced"}
        end

      {err, _} ->
        {:error, err}
    end
  end

  def build_dir(dir, lang) when lang in ["js", "ts"] do
    abs = Path.expand(dir)
    out = Path.join(@cache, "#{cache_key([abs])}.wasm")
    js = Path.join(System.tmp_dir!(), "wb-dir-#{cache_key([abs])}.js")
    File.mkdir_p!(@cache)
    # bun install resolves the dir's npm dependencies; bun build inlines them.
    System.cmd("bun", ["install"], cd: abs, stderr_to_stdout: true)

    case System.cmd("bun", ["build", Path.join(abs, "index.js"), "--outfile", js], stderr_to_stdout: true) do
      {_, 0} -> build_js(File.read!(js), out)
      {err, _} -> {:error, err}
    end
  end

  # Mode 2 — Go. Compile a real Go project dir (its own `go.mod`, multi-file `main`
  # package) to a runnable WASI command via TinyGo (`-target=wasip1`): argv + stdin
  # → stdout, the universal CLI ABI. If the dir has no `go.mod` we synthesize a
  # minimal one (TinyGo refuses a bare main.go), so a single-file fixture also builds.
  def build_dir(dir, lang) when lang in ["go", "tinygo"] do
    abs = Path.expand(dir)
    out = Path.join(@cache, "#{cache_key(["godir", abs])}.wasm")
    File.mkdir_p!(@cache)
    ensure_go_mod(abs)
    env = [{"PATH", "/opt/homebrew/bin:#{System.get_env("PATH")}"}]

    case System.cmd("tinygo", ["build", "-o", out, "-target=wasip1", "."],
           cd: abs,
           stderr_to_stdout: true,
           env: env
         ) do
      {_, 0} -> {:ok, out, :built_dir}
      {err, _} -> {:error, err}
    end
  end

  # Mode 2 — C. Compile a real C project dir (multi-file, its own headers) to a
  # runnable wasm32-wasi command via `zig cc`, linking the mmap shim so a CLI that
  # calls mmap()/munmap()/msync() works unmodified (wasi-libc's mmap just returns
  # ENOSYS). All *.c under the dir are compiled together.
  def build_dir(dir, "c") do
    abs = Path.expand(dir)

    case Path.wildcard(Path.join(abs, "**/*.c")) do
      [] -> {:error, "no .c sources in #{abs}"}
      srcs -> build_c_sources(srcs, Path.join(@cache, "#{cache_key(["cdir", abs])}.wasm"))
    end
  end

  def build_dir(_dir, lang), do: {:error, {:unsupported_dir_lang, lang}}

  # TinyGo needs a module: if the dir has no go.mod, write a minimal one named
  # after the dir so a single-file `main` package still compiles.
  defp ensure_go_mod(abs) do
    mod = Path.join(abs, "go.mod")

    unless File.exists?(mod) do
      name = abs |> Path.basename() |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
      File.write!(mod, "module #{name}\n\ngo 1.21\n")
    end
  end

  defp component_crate?(manifest),
    do: File.exists?(manifest) and File.read!(manifest) =~ "[package.metadata.component]"

  # cargo-component installs to ~/.cargo/bin; the engine may run without it on PATH.
  defp tool_bin("cargo-component"), do: Path.expand("~/.cargo/bin/cargo-component")
  defp tool_bin(other), do: other
  defp cargo_env, do: [{"PATH", "#{Path.expand("~/.cargo/bin")}:#{System.get_env("PATH")}"}]

  defp compile("js", src, out), do: build_js(src, out)
  defp compile("ts", src, out), do: build_ts(src, out)
  defp compile("rust", src, out), do: build_rust(src, out)
  defp compile("go", src, out), do: build_go(src, out)
  defp compile("c", src, out), do: build_c(src, out)
  defp compile(other, _src, _out), do: {:error, {:unsupported_lang, other}}

  # The mmap emulation shim, linked into every C/wasi build (see build_c_sources).
  @mmap_shim Path.expand(Path.join([__DIR__, "..", "build", "shims", "mmap_shim.c"]))
  # Calls to these get rerouted to the shim's __wrap_* via wasm-ld --wrap.
  @mmap_wraps ["--wrap=mmap", "--wrap=munmap", "--wrap=msync"]

  # C = compile to wasm32-wasi via `zig cc` (bundles clang + wasi-libc; no SDK).
  defp build_c(src, out) do
    File.mkdir_p!(@cache)
    c = Path.join(@cache, "c-#{cache_key([src])}.c")
    File.write!(c, src)
    build_c_sources([c], out)
  end

  # Shared C/wasi compile+link used by inline `c` blocks AND build_dir(_, "c").
  #
  # mmap emulation: wasi-libc ships an mmap that just returns ENOSYS, so we link
  # build/shims/mmap_shim.c (a file-backed mmap over pread/pwrite) and redirect
  # mmap/munmap/msync to its __wrap_* with `wasm-ld --wrap`. zig 0.16's cc front
  # end rejects --wrap, so we two-phase it: (1) compile every source + the shim to
  # objects; (2) ask `zig cc -v` for the exact wasm-ld link line (its sysroot/libc
  # paths live in zig's cache, so we never hardcode them — this stays correct
  # across zig versions/cache clears), then replay that line through `wasm-ld`
  # with the --wrap flags injected. The probe link is expected to fail on the
  # mmap dup-symbol; we only need the line it prints. CLI source is untouched.
  defp build_c_sources(srcs, out) do
    File.mkdir_p!(@cache)
    env = [{"PATH", "/opt/homebrew/bin:#{System.get_env("PATH")}"}]
    work = Path.join(@cache, "cobj-#{cache_key(srcs ++ [@mmap_shim])}")
    File.mkdir_p!(work)

    all = srcs ++ [@mmap_shim]
    objs = Enum.map(all, fn s -> Path.join(work, "#{cache_key([s])}.o") end)

    with :ok <- compile_objects(all, objs, env),
         {:ok, ld_line} <- probe_link_line(objs, out, env),
         :ok <- wrap_link(ld_line, env) do
      {:ok, out, :built}
    end
  end

  defp compile_objects(srcs, objs, env) do
    Enum.zip(srcs, objs)
    |> Enum.reduce_while(:ok, fn {src, obj}, _ ->
      case System.cmd("zig", ["cc", "-target", "wasm32-wasi", "-Oz", "-c", "-o", obj, src],
             stderr_to_stdout: true, env: env) do
        {_, 0} -> {:cont, :ok}
        {err, _} -> {:halt, {:error, err}}
      end
    end)
  end

  # Ask zig for the real wasm-ld invocation. The link itself fails (mmap defined
  # in both libc and the shim), but `-v` prints the full command first; we parse
  # that single `wasm-ld …` line. Returns the line minus the leading "wasm-ld ".
  defp probe_link_line(objs, out, env) do
    {output, _} =
      System.cmd("zig", ["cc", "-target", "wasm32-wasi", "-Oz", "-o", out] ++ objs ++ ["-v"],
        stderr_to_stdout: true, env: env)

    case output |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "wasm-ld ")) do
      nil -> {:error, "could not capture wasm-ld link line:\n#{output}"}
      line -> {:ok, String.replace_prefix(line, "wasm-ld ", "")}
    end
  end

  # Replay the captured link, injecting --wrap so mmap/munmap/msync resolve to the
  # shim. zig's link line is plain whitespace-separated absolute paths/flags
  # (no quoting), so a simple split is safe.
  defp wrap_link(ld_line, env) do
    args = @mmap_wraps ++ String.split(ld_line, ~r/\s+/, trim: true)

    case System.cmd("wasm-ld", args, stderr_to_stdout: true, env: env) do
      {_, 0} -> :ok
      {err, _} -> {:error, err}
    end
  end

  # Go = compile a single-file main package to wasm via TinyGo (WASI stdio).
  defp build_go(src, out) do
    File.mkdir_p!(@cache)
    dir = Path.join(@cache, "go-#{cache_key([src])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "main.go"), src)
    env = [{"PATH", "/opt/homebrew/bin:#{System.get_env("PATH")}"}]

    case System.cmd("tinygo", ["build", "-o", out, "-target=wasip1", Path.join(dir, "main.go")],
           stderr_to_stdout: true,
           env: env
         ) do
      {_, 0} -> {:ok, out, :built}
      {err, _} -> {:error, err}
    end
  end

  @jsworkbook_wit Path.expand(Path.join([__DIR__, "..", "wit", "jsworkbook.wit"]))

  @doc """
  Componentize a JS Workbook (a module that `export`s `run(input)`) into a real
  WIT-typed Component via jco/StarlingMonkey — so a Workbook can be authored in
  JS, not just Rust, and run in an Instance against the Dock. Unused WASI features
  are disabled to slim it. Returns {:ok, wasm, :built_js_component}.
  """
  def build_engine_js(src, world_wit \\ @jsworkbook_wit) do
    File.mkdir_p!(@cache)
    js = Path.join(@cache, "jswb-#{cache_key([src])}.js")
    out = Path.join(@cache, "jswb-#{cache_key([src])}.wasm")
    File.write!(js, src)

    args =
      ["componentize", js, "--wit", world_wit, "--world-name", "workbook",
       "--disable", "http", "clocks", "random", "stdio", "-o", out]

    case System.cmd(@jco, args, stderr_to_stdout: true) do
      {_, 0} -> {:ok, out, :built_js_component}
      {err, _} -> {:error, err}
    end
  end

  # Node-compat shims on StarlingMonkey (wb-11ck.37, incremental). StarlingMonkey
  # already gives modern JS (JSON, fetch, TextEncoder, console); this preamble
  # adds the common Node globals so Node-style modules run. fs→VFS and
  # net→net-fetch are the next slices (need the component to import those Dock funcs).
  @node_preamble ~S"""
  globalThis.global = globalThis.global || globalThis;
  globalThis.process = globalThis.process || { env: {}, platform: "wasm", argv: [], cwd: () => "/" };
  globalThis.Buffer = globalThis.Buffer || {
    from: (s) => new TextEncoder().encode(typeof s === "string" ? s : String(s)),
    isBuffer: (x) => x instanceof Uint8Array,
  };
  """

  @doc """
  Build a Node-style JS Workbook: prepend the Node-compat preamble, then
  componentize as a JS Workbook component (wb-11ck.37). Lets a module that uses
  `Buffer` / `process` run on the WASM substrate.
  """
  def build_node_js(src, world_wit \\ @jsworkbook_wit) do
    build_engine_js(@node_preamble <> "\n" <> src, world_wit)
  end

  defp build_js(src, out) do
    File.mkdir_p!(@cache)
    tmp = Path.join(System.tmp_dir!(), "wb-#{cache_key([src])}.js")
    File.write!(tmp, src)

    case System.cmd(@javy, ["build", tmp, "-o", out], stderr_to_stdout: true) do
      {_, 0} -> {:ok, out, :built}
      {err, _} -> {:error, err}
    end
  end

  # TS = strip types + bundle with bun, then the JS path.
  defp build_ts(src, out) do
    ts = Path.join(System.tmp_dir!(), "wb-#{cache_key([src])}.ts")
    js = Path.join(System.tmp_dir!(), "wb-#{cache_key([src])}.built.js")
    File.write!(ts, src)

    case System.cmd("bun", ["build", ts, "--outfile", js], stderr_to_stdout: true) do
      {_, 0} -> build_js(File.read!(js), out)
      {err, _} -> {:error, err}
    end
  end

  # Rust = scaffold a one-file binary crate and compile to wasm32-wasip1.
  defp build_rust(src, out) do
    dir = Path.join(@cache, "rust-#{cache_key([src])}")
    File.mkdir_p!(Path.join(dir, "src"))
    File.write!(Path.join(dir, "Cargo.toml"), rust_cargo())
    File.write!(Path.join([dir, "src", "main.rs"]), src)

    cmd = ["build", "--manifest-path", Path.join(dir, "Cargo.toml"), "--target", "wasm32-wasip1", "--release"]

    case System.cmd("cargo", cmd, stderr_to_stdout: true) do
      {_, 0} ->
        File.cp!(Path.join([dir, "target", "wasm32-wasip1", "release", "comp.wasm"]), out)
        {:ok, out, :built}

      {err, _} ->
        {:error, err}
    end
  end

  defp rust_cargo do
    """
    [package]
    name = "comp"
    version = "0.1.0"
    edition = "2021"
    [workspace]
    [[bin]]
    name = "comp"
    path = "src/main.rs"
    [profile.release]
    opt-level = "z"
    """
  end

  @doc """
  Content-address a built command artifact: hash its BYTES (sha256), copy it to
  `build/commands/<sha>.wasm`, and return that stable path. Identical source ⇒
  identical wasm ⇒ identical hash ⇒ same path — so rebuilds are idempotent (the
  copy is skipped when the addressed file already exists). This is the path a
  command is REGISTERED under, decoupling the registry from transient cache/temp
  build outputs. Returns {:ok, addressed_path, sha} | {:error, reason}.
  """
  def content_address(wasm_path) do
    case File.read(wasm_path) do
      {:ok, bytes} ->
        sha = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
        File.mkdir_p!(@commands)
        addressed = Path.join(@commands, "#{sha}.wasm")
        unless File.exists?(addressed), do: File.write!(addressed, bytes)
        {:ok, addressed, sha}

      {:error, reason} ->
        {:error, {:read_artifact, wasm_path, reason}}
    end
  end

  @doc """
  Capture a built CLI's `--help` text by running the wasm command with argv
  `["--help"]` and no stdin. The agent reads this the way a human reads `--help`;
  per TOOLKITS-V3 it MAY seed an overview/leaf skill draft (never a substitute for
  the hand-authored semantic surface). Returns the captured text (stdout+stderr).
  """
  def capture_help(wasm_path, flag \\ "--help"), do: run(wasm_path, "", [flag])

  @doc "Run a built WASM component with input, returning its output (WASI stdin/stdout)."
  def run(wasm_path, input), do: run(wasm_path, input, [])

  @doc """
  Run a built WASM command with stdin `input` AND `argv` — the universal CLI ABI
  (argv + stdin → stdout). This is what lets an unmodified upstream CLI compiled
  to wasm32-wasip1 (e.g. `sd`, `jq`) be driven exactly as on a native shell.
  `dirs` are host paths preopened into the guest (WASI `--dir`) for file-mode CLIs.
  argv/dirs are passed as discrete System.cmd args (no shell), so no injection.
  """
  def run(wasm_path, input, argv, dirs \\ []) when is_list(argv) do
    inp = Path.join(System.tmp_dir!(), "wb-in-#{:erlang.unique_integer([:positive])}")
    File.write!(inp, input)
    parts = Enum.flat_map(dirs, &["--dir", &1]) ++ [wasm_path | argv]
    cmd = "wasmtime " <> Enum.map_join(parts, " ", &sh_escape/1) <> " < " <> sh_escape(inp)
    {out, _} = System.cmd("sh", ["-c", cmd], stderr_to_stdout: true)
    File.rm(inp)
    out
  end

  # POSIX single-quote escaping: wrap in '...' and replace ' with '\'' — no injection.
  defp sh_escape(s), do: "'" <> String.replace(to_string(s), "'", "'\\''") <> "'"

  @doc """
  Execute a Workbook's DAG: build each component, run them in topological order,
  and pipe each one's stdout into its consumer's stdin along the OQL `:out`→`:in`
  edges. Host-orchestrated dataflow — composes stdin/stdout filters (stock Javy,
  any language) without WIT. Typed in-WASM composition (wac plug) is the upgrade,
  and needs WIT-declared components (jco / cargo-component). Returns name → output.
  """
  def run_dag(org, input) do
    Workbooks.OQL.tangle_plan(org) |> Map.get("worlds") |> hd() |> run_world(input)
  end

  @doc """
  Run one world's DAG in topological order, piping each producer's output into its
  consumer along the `:out`→`:in` edges. `step_fn.(component, input)` runs one
  step — the default builds + runs the component as a WASM filter; `Workbooks.
  Workflow` passes a step_fn that also runs `agent` steps. Returns name → output.
  """
  def run_world(world, input, step_fn \\ &run_component_step/2) do
    comps = Map.new(world["components"], &{&1["name"], &1})
    producer = Map.new(world["edges"], fn e -> {e["to"], e["from"]} end)

    # Topological *waves*: each wave's steps have all predecessors done, so they
    # run in parallel — independent steps (a fan-out of sub-agents) run at once.
    Enum.reduce(waves(world["components"], world["edges"]), %{}, fn wave, acc ->
      wave
      |> Task.async_stream(
        fn name ->
          in_data = if from = producer[name], do: acc[from], else: input
          {name, step_fn.(comps[name], in_data)}
        end,
        timeout: 600_000,
        max_concurrency: 8
      )
      |> Enum.reduce(acc, fn {:ok, {name, out}}, a -> Map.put(a, name, out) end)
    end)
  end

  @doc "Default step: build the component and run it as a WASM stdin/stdout filter."
  def run_component_step(comp, input) do
    case build(comp) do
      {_, _, {:ok, wasm, _}} -> run(wasm, input) |> String.trim()
      {_, _, other} -> {:error, other}
    end
  end

  # Topological waves: each wave is the set of steps whose predecessors are all
  # done. Steps within a wave are independent → run in parallel.
  defp waves(comps, edges) do
    preds = Enum.group_by(edges, & &1["to"], & &1["from"])
    build_waves(Enum.map(comps, & &1["name"]), preds, [], [])
  end

  defp build_waves([], _preds, _done, acc), do: Enum.reverse(acc)

  defp build_waves(remaining, preds, done, acc) do
    case Enum.filter(remaining, fn n -> Enum.all?(Map.get(preds, n, []), &(&1 in done)) end) do
      [] -> Enum.reverse([remaining | acc])
      ready -> build_waves(remaining -- ready, preds, done ++ ready, [ready | acc])
    end
  end

  @doc """
  Componentize: wrap a Javy CORE module into a Component-Model component using the
  WASI preview1 adapter (`wasm-tools component new --adapt`). Required because Javy
  emits a CORE module but `wac` only links COMPONENTS. Cached by core path + adapter.
  """
  def componentize(core_wasm) do
    out = Path.join(@cache, "#{cache_key([core_wasm, @adapter])}.component.wasm")

    cond do
      File.exists?(out) ->
        {:ok, out, :cached}

      true ->
        args = ["component", "new", core_wasm, "--adapt", "wasi_snapshot_preview1=#{@adapter}", "-o", out]

        case System.cmd(@wasm_tools, args, stderr_to_stdout: true) do
          {_, 0} -> {:ok, out, :built}
          {err, _} -> {:error, err}
        end
    end
  end

  @doc """
  Compose a list of component wasm paths into ONE valid component via `wac compose`.
  This is a STRUCTURAL bundle: each input is instantiated and re-exported under a
  name. It is NOT typed dataflow (plug one component's output into another's input):
  Javy core modules declare no custom WIT import/export interface — their data flows
  over WASI stdin/stdout, not over component-model edges — so `wac plug` finds no
  matching imports. Typed JS→JS composition needs WIT-declared worlds (componentize-js
  / jco), not stock Javy. See docs/COMPOSE-NOTES.org.
  """
  def compose(components) when is_list(components) and components != [] do
    key = cache_key(["compose" | components])
    out = Path.join(@cache, "#{key}.composed.wasm")
    script = Path.join(@cache, "#{key}.wac")
    File.write!(script, compose_doc(components))

    deps =
      components
      |> Enum.with_index()
      |> Enum.flat_map(fn {path, i} -> ["--dep", "wb:c#{i}=#{path}"] end)

    case System.cmd(@wac, ["compose", script] ++ deps ++ ["-o", out], stderr_to_stdout: true) do
      {_, 0} -> {:ok, out, :composed}
      {err, _} -> {:error, err}
    end
  end

  defp compose_doc(components) do
    idx = 0..(length(components) - 1)
    lets = Enum.map(idx, &"let c#{&1} = new wb:c#{&1} { ... };")
    exports = Enum.map(idx, &~s(export c#{&1} as "c#{&1}";))
    Enum.join(["package wb:composed;" | lets ++ exports], "\n")
  end

  @doc """
  Typed composition — real in-WASM dataflow, the upgrade over `compose/1`'s
  structural bundle. Lowers an OQL `:out`→`:in` edge into a WIT `stage`
  interface, componentizes each component's JS against the generated WIT world
  via *jco* (NOT Javy — Javy declares no WIT, so `wac plug` finds nothing to
  wire), then `wac plug`s producer.export(stage) → consumer.import(stage) into
  ONE component whose only remaining imports are WASI. See docs/COMPOSE-NOTES.org.

  Scope: one producer→consumer JS edge (the 2-component pipeline). The JS speaks
  the typed contract — the producer `export const stage = { apply(x) }`, the
  consumer `import { apply } from 'wb:pipe/stage'` and `export function run(x)` —
  not Javy stdin/stdout. Multi-edge DAG folding is the next step.
  """
  def typed_compose(org) when is_binary(org) do
    world = Workbooks.OQL.tangle_plan(org) |> Map.get("worlds") |> hd()
    comps = Map.new(world["components"], &{&1["name"], &1})

    case world["edges"] do
      [%{"from" => from, "to" => to} | _] ->
        t = wit_type(comps[from]["out"])
        wit = Path.join(@cache, "#{cache_key([from, to, t])}.pipe.wit")
        File.mkdir_p!(@cache)
        File.write!(wit, pipe_wit(t))

        with {:ok, plug} <- componentize_typed(comps[from]["src"], wit, "producer"),
             {:ok, socket} <- componentize_typed(comps[to]["src"], wit, "consumer"),
             {:ok, out} <- plug(socket, plug) do
          {:ok, out, :typed}
        end

      _ ->
        {:error, :no_edge_to_type}
    end
  end

  # OQL field "label:type" → WIT type. Generic types we don't model become bytes.
  defp wit_type(nil), do: "string"

  defp wit_type(field) do
    case field |> String.split(":") |> List.last() do
      "f64" -> "f64"
      "number" -> "f64"
      "bytes" -> "list<u8>"
      "list" -> "list<u8>"
      _ -> "string"
    end
  end

  defp pipe_wit(t) do
    """
    package wb:pipe;
    interface stage { apply: func(input: #{t}) -> #{t}; }
    world producer { export stage; }
    world consumer { import stage; export run: func(input: #{t}) -> #{t}; }
    """
  end

  @doc "Componentize JS against a WIT world via jco (real typed component)."
  def componentize_typed(src, wit, world) do
    js = Path.join(System.tmp_dir!(), "wb-jco-#{cache_key([src, world])}.js")
    out = Path.join(@cache, "#{cache_key([src, wit, world])}.typed.wasm")
    File.write!(js, src)

    if File.exists?(out) do
      {:ok, out}
    else
      args = ["componentize", js, "--wit", wit, "--world-name", world, "-o", out]

      case System.cmd(@jco, args, stderr_to_stdout: true) do
        {_, 0} -> {:ok, out}
        {err, _} -> {:error, err}
      end
    end
  end

  # wac plug: link the plug's exported interface to the socket's imported one.
  defp plug(socket, plug) do
    out = Path.join(@cache, "#{cache_key([socket, plug])}.plugged.wasm")

    case System.cmd(@wac, ["plug", socket, "--plug", plug, "-o", out], stderr_to_stdout: true) do
      {_, 0} -> {:ok, out}
      {err, _} -> {:error, err}
    end
  end

  @doc "Validate a component artifact with `wasm-tools validate`."
  def validate_component(path) do
    case System.cmd(@wasm_tools, ["validate", path], stderr_to_stdout: true) do
      {_, 0} -> :valid
      {err, _} -> {:invalid, err}
    end
  end

  @doc "Content-addressed cache key for a build input set."
  def cache_key(parts),
    do: :crypto.hash(:sha256, Enum.join(parts, "\0")) |> Base.encode16(case: :lower)
end
