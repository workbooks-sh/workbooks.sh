defmodule Workbooks.PackageManager.Compose do
  @moduledoc """
  Component-Model composition: wrap a core module into a component (wasm-tools
  component new), structurally bundle components (wac compose), and the typed
  in-WASM dataflow path (jco componentize + wac plug). Used only by the demo /
  advanced build path (host/demos/build.ex), NOT the core stdin/stdout dataflow.
  Split out of `Workbooks.PackageManager`, which delegates the public entry points
  (componentize, compose, typed_compose, componentize_typed, validate_component) here.

  wb-fm0.8: `wasm-tools` (component new / validate) runs IN the sandbox via
  wasm-tools.wasm. `wac` (compose/plug) and `jco`/componentize-js stay native —
  they compose already-built, validated TRUSTED components (byte manipulation,
  never untrusted-source compilation), so they sit outside the untrusted-source canon.
  """

  alias Workbooks.PackageManager
  alias Workbooks.PackageManager.{Paths, Run}

  @wac Path.join(Paths.tools(), "wac")
  # jco/componentize-js (node_modules/.bin) — the ONLY path that emits a real
  # WIT-typed component from JS. `bun install` in runtime/ provisions it.
  @jco Path.expand(Path.join([__DIR__, "..", "..", "node_modules", ".bin", "jco"]))
  # Javy emits a CORE command module (exports `_start`) → use the command adapter:
  # it both validates AND runs under wasmtime. The reactor adapter yields an
  # export-less component that can be neither run nor composed (see COMPOSE-NOTES.org).
  @adapter Path.join(Paths.tools(), "wasi_snapshot_preview1.command.wasm")
  # wasm-tools built to wasm32-wasip1 (compilers/wasm-tools/build.sh) — runs IN the sandbox
  # via wasmtime (wb-fm0.8). It manipulates already-built, validated wasm BYTES (component
  # new/validate); it never compiles untrusted source, but routing it through wasmtime keeps
  # the whole tool surface native-free.
  @wasm_tools_wasm Path.join(Paths.tools(), "wasm-tools.wasm")
  @jsworkbook_wit Path.expand(Path.join([__DIR__, "..", "..", "wit", "jsworkbook.wit"]))

  # Run wasm-tools.wasm under wasmtime, preopening each dir it must read/write at the SAME guest
  # path so the tool's absolute-path args resolve unchanged. Self-heals the .wasm via build.sh.
  defp wasm_tools(args, dirs) do
    unless File.regular?(@wasm_tools_wasm) do
      System.cmd("bash", [Path.expand(Path.join([__DIR__, "..", "..", "compilers", "wasm-tools", "build.sh"]))],
        stderr_to_stdout: true)
    end

    preopens = Enum.flat_map(Enum.uniq(dirs), fn d -> ["--dir", "#{d}::#{d}"] end)
    System.cmd("wasmtime", ["run"] ++ Run.wasmtime_cache_args() ++ ["-W", "exceptions=y"] ++ preopens ++ [@wasm_tools_wasm | args],
      stderr_to_stdout: true)
  end

  @doc """
  Componentize: wrap a Javy CORE module into a Component-Model component using the
  WASI preview1 adapter (`wasm-tools component new --adapt`). Required because Javy
  emits a CORE module but `wac` only links COMPONENTS. Cached by core path + adapter.
  Runs wasm-tools IN the sandbox (wasm-tools.wasm under wasmtime) — wb-fm0.8.
  """
  def componentize(core_wasm) do
    ensure_adapter()
    out = Path.join(Paths.cache(), "#{PackageManager.cache_key([core_wasm, @adapter])}.component.wasm")

    cond do
      File.exists?(out) ->
        {:ok, out, :cached}

      true ->
        args = ["component", "new", core_wasm, "--adapt", "wasi_snapshot_preview1=#{@adapter}", "-o", out]

        case wasm_tools(args, [Paths.cache(), Path.dirname(core_wasm), Path.dirname(@adapter)]) do
          {_, 0} -> {:ok, out, :built}
          {err, _} -> {:error, err}
        end
    end
  end

  # The WASI preview1 command adapter is a STATIC wasm shipped in jco's node_modules. Copy it
  # into build/tools on first use; fall back to full Tools provisioning if node_modules is absent.
  defp ensure_adapter do
    unless File.regular?(@adapter) do
      src = Path.expand(Path.join([__DIR__, "..", "..", "node_modules", "@bytecodealliance", "jco", "lib", "wasi_snapshot_preview1.command.wasm"]))
      File.mkdir_p!(Paths.tools())
      if File.regular?(src), do: File.cp!(src, @adapter), else: Workbooks.Tools.ensure!()
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

  wb-fm0.8 carve-out: `wac` stays native (its tokio dep doesn't compile to wasi). It
  composes already-built, validated TRUSTED components — byte manipulation, never the
  compilation of untrusted source — and is used only by host/demos/build.ex, so it sits
  outside the untrusted-source canon. `wasm-tools` (component new/validate) DID move
  in-sandbox; `wac` is the one wasm-byte tool that couldn't follow.
  """
  def compose(components) when is_list(components) and components != [] do
    Workbooks.Tools.ensure!()
    key = PackageManager.cache_key(["compose" | components])
    out = Path.join(Paths.cache(), "#{key}.composed.wasm")
    script = Path.join(Paths.cache(), "#{key}.wac")
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
  structural bundle. Lowers a work-component `out`→`in` edge into a WIT `stage`
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
    world = Workbooks.Workbook.tangle_plan(org) |> Map.get("worlds") |> hd()
    comps = Map.new(world["components"], &{&1["name"], &1})

    case world["edges"] do
      [%{"from" => from, "to" => to} | _] ->
        t = wit_type(comps[from]["out"])
        wit = Path.join(Paths.cache(), "#{PackageManager.cache_key([from, to, t])}.pipe.wit")
        File.mkdir_p!(Paths.cache())
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

  # Workbook field "label:type" → WIT type. Generic types we don't model become bytes.
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
    js = Path.join(System.tmp_dir!(), "wb-jco-#{PackageManager.cache_key([src, world])}.js")
    out = Path.join(Paths.cache(), "#{PackageManager.cache_key([src, wit, world])}.typed.wasm")
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
    out = Path.join(Paths.cache(), "#{PackageManager.cache_key([socket, plug])}.plugged.wasm")

    case System.cmd(@wac, ["plug", socket, "--plug", plug, "-o", out], stderr_to_stdout: true) do
      {_, 0} -> {:ok, out}
      {err, _} -> {:error, err}
    end
  end

  @doc "Validate a component artifact with `wasm-tools validate`, run IN the sandbox (wb-fm0.8)."
  def validate_component(path) do
    case wasm_tools(["validate", path], [Path.dirname(path)]) do
      {_, 0} -> :valid
      {err, _} -> {:invalid, err}
    end
  end

  @doc """
  Componentize a JS Workbook (a module that `export`s `run(input)`) into a real
  WIT-typed Component via jco/StarlingMonkey — so a Workbook can be authored in
  JS, not just Rust, and run in an Instance against the Dock. Unused WASI features
  are disabled to slim it. Returns {:ok, wasm, :built_js_component}.

  ── wb-fm0.7 — HONEST NATIVE BLOCKER ─────────────────────────────────────────
  This is the ONE build path that stays native, and deliberately so. jco /
  componentize-js generates a WIT-typed Component by running StarlingMonkey (a JS
  engine) under Node + `wizer` snapshotting — it EXECUTES the JS at build time to
  pre-initialize it. That can't move in-sandbox: it needs Node (V8, a JIT — see
  the JIT note) plus StarlingMonkey + wizer, none of which run as a wasmtime guest.
  There is no QuickJS→WIT-typed-component path (StarlingMonkey-equivalent + wizer
  in wasm don't exist).

  Why this is acceptable: typed WIT components are an OPTIONAL advanced feature used
  only by host/demos/build.ex — the core runtime dataflow (run_world/run_dag) pipes
  stdin/stdout between WASI command modules, which the 6 in-sandbox lanes
  (C/Zig/Rust/JS/Go/TS) produce with ZERO native compilation. So the untrusted-source
  canon ("user code never compiles/runs natively") is fully met; typed-component
  GENERATION via jco is out of scope and may use the native tool. If a fully
  in-sandbox typed-component path is ever needed, it requires a new WIT-aware JS
  engine in wasm — tracked, not blocking.
  """
  def build_engine_js(src, world_wit \\ @jsworkbook_wit) do
    Workbooks.Tools.ensure_jco!()
    File.mkdir_p!(Paths.cache())
    js = Path.join(Paths.cache(), "jswb-#{PackageManager.cache_key([src])}.js")
    out = Path.join(Paths.cache(), "jswb-#{PackageManager.cache_key([src])}.wasm")
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
end
