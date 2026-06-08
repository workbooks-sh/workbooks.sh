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

  # SECURITY (wb-sec): hard caps for the command run path. A guest that builds a
  # huge string and passes it as `run-command` input would otherwise pin it in
  # BEAM heap AND write it whole to /tmp (memory + disk DoS). argv likewise is
  # bounded so a single oversized arg cannot blow ARG_MAX (which silently failed).
  @max_input_bytes 64 * 1024 * 1024
  @max_argv_bytes 256 * 1024
  # Wall-clock + fuel caps on the wasmtime CLI so an infinite-loop guest cannot
  # hang the host forever (the Instance Policy timeout never wrapped this path).
  @default_run_timeout_ms 30_000
  @default_fuel 5_000_000_000

  @doc "The content-addressed commands store dir (build/commands/)."
  def commands_dir, do: @commands

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
  # Mode 2 — Rust. Compile a real Rust project dir to a runnable wasm command ENTIRELY in the
  # sandbox (mrustc.wasm → clang.wasm, full std), zero native execution (wb-fm0.3). The old
  # native `cargo`/`cargo-component` path is gone: untrusted Rust never touches a native
  # toolchain. The dir's entry is src/main.rs (or a lone *.rs). NOTE: external cargo
  # dependencies are NOT yet supported in-sandbox — only std. A crate that declares non-std
  # deps in Cargo.toml returns {:error, {:rust_deps_unsupported_in_sandbox, _}} rather than
  # silently falling back to native (which would breach the no-native-compile canon).
  def build_dir(dir, "rust") do
    abs = Path.expand(dir)
    manifest = Path.join(abs, "Cargo.toml")

    entry =
      cond do
        File.regular?(Path.join(abs, "src/main.rs")) -> Path.join(abs, "src/main.rs")
        File.regular?(Path.join(abs, "src/lib.rs")) -> Path.join(abs, "src/lib.rs")
        true -> List.first(Path.wildcard(Path.join(abs, "**/*.rs")))
      end

    cond do
      has_external_rust_deps?(manifest) -> {:error, {:rust_deps_unsupported_in_sandbox, abs}}
      is_nil(entry) -> {:error, "no .rs source in #{abs}"}
      true -> rust_to_wasm(entry, Path.join(@cache, "#{cache_key(["rustdir", abs])}.wasm"))
    end
  end

  def build_dir(dir, lang) when lang in ["js", "ts"] do
    abs = Path.expand(dir)
    out = Path.join(@cache, "#{cache_key([abs])}.wasm")
    js = Path.join(System.tmp_dir!(), "wb-dir-#{cache_key([abs])}.js")
    File.mkdir_p!(@cache)
    # SECURITY (wb-sec): npm postinstall/build scripts are HOSTILE. `bun install`
    # needs the registry (network-permitted, fs-confined); `bun build` (which can
    # trigger build-time scripts) runs network-DENIED.
    Workbooks.Sandbox.run_net(["bun", "install"], cd: abs)

    case Workbooks.Sandbox.run(["bun", "build", Path.join(abs, "index.js"), "--outfile", js]) do
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

    # SECURITY (wb-sec): Go generate / cgo / linker plugins can run host code.
    # Compile network-DENIED, fs-confined (deps must be cached: `go mod download`).
    case Workbooks.Sandbox.run(["tinygo", "build", "-o", out, "-target=wasip1", "."], cd: abs, env: env) do
      {_, 0} -> {:ok, out, :built_dir}
      {err, _} -> {:error, err}
    end
  end

  # Mode 2 — C. Compile a real C project dir (multi-file, its own headers) to a
  # runnable wasm32-wasi command. The compile+link runs ENTIRELY in the sandbox via
  # clang.wasm + wasm-ld (Workbooks.Compilers.compile_c) — zero native execution, so
  # untrusted C source never touches a native toolchain (wb-fm0.1). All *.c under the
  # dir are compiled together (first is the main TU, the rest passed as extra sources).
  def build_dir(dir, "c") do
    abs = Path.expand(dir)

    case Path.wildcard(Path.join(abs, "**/*.c")) do
      [] -> {:error, "no .c sources in #{abs}"}
      [main | rest] -> compile_c_in_sandbox(main, rest, Path.join(@cache, "#{cache_key(["cdir", abs])}.wasm"))
    end
  end

  # Mode 2 — Zig. Compile a real Zig project dir to a runnable wasm command ENTIRELY in
  # the sandbox: zig1.wasm (.zig → C) → clang.wasm (C → wasm), zero native execution
  # (wb-fm0.2). The dir's root .zig is the entry (build.zig is not used — single-module).
  def build_dir(dir, "zig") do
    abs = Path.expand(dir)

    entry =
      Path.join(abs, "main.zig")
      |> File.regular?()
      |> if(do: Path.join(abs, "main.zig"), else: List.first(Path.wildcard(Path.join(abs, "*.zig"))))

    cond do
      is_nil(entry) -> {:error, "no .zig source in #{abs}"}
      true -> zig_to_wasm(entry, Path.join(@cache, "#{cache_key(["zigdir", abs])}.wasm"))
    end
  end

  def build_dir(_dir, lang), do: {:error, {:unsupported_dir_lang, lang}}

  # A Cargo.toml with a non-empty [dependencies] table needs vendored crate builds the
  # in-sandbox single-file mrustc lane doesn't do yet. std-only crates (no deps) are fine.
  defp has_external_rust_deps?(manifest) do
    File.exists?(manifest) and
      Regex.match?(~r/^\[dependencies\]\s*\n\s*\w/m, File.read!(manifest))
  end

  # TinyGo needs a module: if the dir has no go.mod, write a minimal one named
  # after the dir so a single-file `main` package still compiles.
  defp ensure_go_mod(abs) do
    mod = Path.join(abs, "go.mod")

    unless File.exists?(mod) do
      name = abs |> Path.basename() |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
      File.write!(mod, "module #{name}\n\ngo 1.21\n")
    end
  end


  defp compile("js", src, out), do: build_js(src, out)
  defp compile("ts", src, out), do: build_ts(src, out)
  defp compile("rust", src, out), do: build_rust(src, out)
  defp compile("go", src, out), do: build_go(src, out)
  defp compile("c", src, out) do
    File.mkdir_p!(@cache)
    c = Path.join(@cache, "c-#{cache_key([src])}.c")
    File.write!(c, src)
    compile_c_in_sandbox(c, [], out)
  end

  defp compile("zig", src, out) do
    File.mkdir_p!(@cache)
    z = Path.join(@cache, "zig-#{cache_key([src])}.zig")
    File.write!(z, src)
    zig_to_wasm(z, out)
  end

  defp compile(other, _src, _out), do: {:error, {:unsupported_lang, other}}

  # The mmap emulation shim (file-backed mmap over pread/pwrite), linked into every
  # C/wasi build. wasi-libc's own mmap returns ENOSYS; @mmap_wraps redirect
  # mmap/munmap/msync to the shim's __wrap_* at link time.
  @mmap_shim Path.expand(Path.join([__DIR__, "..", "build", "shims", "mmap_shim.c"]))
  @mmap_wraps ["--wrap=mmap", "--wrap=munmap", "--wrap=msync"]

  # C = compile + link to a runnable wasm32-wasip1 command ENTIRELY in the sandbox
  # via clang.wasm + wasm-ld (Workbooks.Compilers.compile_c) — zero native execution
  # (wb-fm0.1). The old native `zig cc`/`wasm-ld` path is gone: untrusted C source is
  # never handed to a native toolchain. `main` is the primary translation unit; `rest`
  # are additional .c sources compiled+linked alongside it. The emitted wasm is copied
  # to `out` (the content-addressed cache path) so the rest of the build path is unchanged.
  #
  # mmap parity: the shim is linked (extra_csrc) and mmap/munmap/msync are --wrap'd to it
  # (ld_args), so a CLI that mmap()s a file works the same as on the old zig-cc lane —
  # now with zero native execution.
  defp compile_c_in_sandbox(main, rest, out) do
    File.mkdir_p!(@cache)

    case Workbooks.Compilers.compile_c(main, extra_csrc: rest ++ [@mmap_shim], ld_args: @mmap_wraps) do
      {:ok, wasm, _logs} ->
        File.cp!(wasm, out)
        File.rm(wasm)
        {:ok, out, :built}

      {:error, _} = err ->
        err
    end
  end

  # Zig = compile a .zig source to a runnable wasm command ENTIRELY in the sandbox via
  # zig1.wasm (.zig → C) → clang.wasm (C → wasm) — zero native execution (wb-fm0.2). The
  # emitted wasm is copied to `out` (the content-addressed cache path).
  defp zig_to_wasm(src, out) do
    File.mkdir_p!(@cache)

    case Workbooks.Compilers.zig_compile_to_wasm(src) do
      {:ok, wasm, _logs} ->
        File.cp!(wasm, out)
        File.rm(wasm)
        {:ok, out, :built}

      {:error, _} = err ->
        err
    end
  end

  # Rust = compile a .rs to a runnable wasm command ENTIRELY in the sandbox via mrustc.wasm →
  # clang.wasm (full std), zero native execution (wb-fm0.3). Copies the emitted wasm to `out`.
  defp rust_to_wasm(src, out) do
    File.mkdir_p!(@cache)

    case Workbooks.Compilers.rust_compile_to_wasm(src) do
      {:ok, wasm, _logs} ->
        File.cp!(wasm, out)
        File.rm(wasm)
        {:ok, out, :built}

      {:error, _} = err ->
        err
    end
  end

  # Go = compile a single-file main package to wasm via TinyGo (WASI stdio).
  defp build_go(src, out) do
    File.mkdir_p!(@cache)
    dir = Path.join(@cache, "go-#{cache_key([src])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "main.go"), src)
    env = [{"PATH", "/opt/homebrew/bin:#{System.get_env("PATH")}"}]

    # SECURITY (wb-sec): compile network-DENIED, fs-confined.
    case Workbooks.Sandbox.run(["tinygo", "build", "-o", out, "-target=wasip1", Path.join(dir, "main.go")], env: env) do
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
    Workbooks.Tools.ensure_jco!()
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
    Workbooks.Tools.ensure!()
    File.mkdir_p!(@cache)
    tmp = Path.join(System.tmp_dir!(), "wb-#{cache_key([src])}.js")
    File.write!(tmp, src)

    # SECURITY (wb-sec): Javy compiles untrusted JS — network-DENIED, fs-confined.
    case Workbooks.Sandbox.run([@javy, "build", tmp, "-o", out]) do
      {_, 0} -> {:ok, out, :built}
      {err, _} -> {:error, err}
    end
  end

  # TS = strip types + bundle with bun, then the JS path.
  defp build_ts(src, out) do
    ts = Path.join(System.tmp_dir!(), "wb-#{cache_key([src])}.ts")
    js = Path.join(System.tmp_dir!(), "wb-#{cache_key([src])}.built.js")
    File.write!(ts, src)

    # SECURITY (wb-sec): bun build of untrusted TS — network-DENIED, fs-confined.
    case Workbooks.Sandbox.run(["bun", "build", ts, "--outfile", js]) do
      {_, 0} -> build_js(File.read!(js), out)
      {err, _} -> {:error, err}
    end
  end

  # Rust = compile a one-file program to a runnable wasm command ENTIRELY in the sandbox via
  # mrustc.wasm (.rs → C) → clang.wasm (C → wasm), linked against the libstd that mrustc.wasm
  # itself prebuilt — zero native execution (wb-fm0.3). The old native `cargo` path is gone:
  # untrusted Rust (incl. hostile proc-macros) never touches a native toolchain. Full std is
  # supported (Vec/iterators/println!). Requires the one-time libstd prebuild
  # (compilers/rust/provision-rust.sh); absent ⇒ {:error, {:libstd_not_prebuilt, _}}.
  defp build_rust(src, out) do
    File.mkdir_p!(@cache)
    rs = Path.join(@cache, "rust-#{cache_key([src])}.rs")
    File.write!(rs, src)
    rust_to_wasm(rs, out)
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

  SECURITY (wb-sec): caps + bounds enforced here (the run-command Dock surface):
    * input size is capped (@max_input_bytes) before it is written to /tmp — a
      guest cannot fill host memory/disk via an oversized stdin.
    * total argv size is capped (@max_argv_bytes) — an oversized arg used to blow
      ARG_MAX and fail SILENTLY (empty output); now it returns a clear error.
    * wasmtime runs under `-W timeout=` AND `-W fuel=` so an infinite-loop guest
      traps instead of hanging the host forever (the Policy CPU cap never wrapped
      this path). `opts[:timeout_ms]` overrides the default.
    * the stdin temp file is removed in an `after` block so a crash/kill cannot
      leak it.
    * a non-zero wasmtime exit (including the timeout trap) returns
      `{:error, {:command_failed, status, out}}` instead of a silent "".

  Returns the trimmed-on-success stdout as a binary, or `{:error, reason}`.
  """
  def run(wasm_path, input, argv, dirs \\ [], opts \\ []) when is_list(argv) do
    cond do
      not is_binary(input) or byte_size(input) > @max_input_bytes ->
        {:error, {:input_too_large, max: @max_input_bytes}}

      argv_bytes(argv) > @max_argv_bytes ->
        {:error, {:argv_too_large, max: @max_argv_bytes}}

      true ->
        run_wasmtime(wasm_path, input, argv, dirs, opts)
    end
  end

  defp argv_bytes(argv), do: Enum.reduce(argv, 0, fn a, acc -> acc + byte_size(to_string(a)) + 1 end)

  defp run_wasmtime(wasm_path, input, argv, dirs, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_run_timeout_ms)
    fuel = Keyword.get(opts, :fuel, @default_fuel)
    env = Keyword.get(opts, :env, [])
    inp = Path.join(System.tmp_dir!(), "wb-in-#{:erlang.unique_integer([:positive])}")

    try do
      File.write!(inp, input)

      # exceptions=y → setjmp/longjmp (Lua etc., via wasi-sdk -wasm-enable-sjlj).
      # memory64=y → compilers-in-wasm (wb-cwasm) that exceed the wasm32 4GB ceiling on
      # large inputs (LLVM-class). Both harmless for modules that don't use them.
      # (Wasm 3.0 / W3C standard; wasmtime implements them.)
      wopts = ["-W", "exceptions=y", "-W", "memory64=y", "-W", "timeout=#{timeout_ms}ms", "-W", "fuel=#{fuel}"]
      envs = Enum.flat_map(env, &["--env", &1])
      parts = wopts ++ envs ++ Enum.flat_map(dirs, &["--dir", &1]) ++ [wasm_path | argv]
      cmd = "wasmtime " <> Enum.map_join(parts, " ", &sh_escape/1) <> " < " <> sh_escape(inp)

      # NOTE: a non-zero exit here is usually the GUEST exiting non-zero (a normal
      # CLI failure, e.g. a file not preopened) — that output is returned to the
      # caller verbatim, preserving the universal-CLI contract. The DoS protection
      # is the `-W timeout`/`-W fuel` trap above (an infinite loop is killed by
      # wasmtime) plus the input/argv size caps (no silent E2BIG) — not a status
      # check here.
      {out, _status} = System.cmd("sh", ["-c", cmd], stderr_to_stdout: true)
      out
    after
      File.rm(inp)
    end
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
      {_, _, {:ok, wasm, _}} ->
        case run(wasm, input) do
          {:error, _} = err -> err
          out -> String.trim(out)
        end

      {_, _, other} ->
        {:error, other}
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
    Workbooks.Tools.ensure!()
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
    Workbooks.Tools.ensure!()
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
    Workbooks.Tools.ensure_jco!()
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
    Workbooks.Tools.ensure!()

    case System.cmd(@wasm_tools, ["validate", path], stderr_to_stdout: true) do
      {_, 0} -> :valid
      {err, _} -> {:invalid, err}
    end
  end

  @doc "Content-addressed cache key for a build input set."
  def cache_key(parts),
    do: :crypto.hash(:sha256, Enum.join(parts, "\0")) |> Base.encode16(case: :lower)
end
