defmodule Workbooks.PackageManager do
  @moduledoc """
  Tangle: take the build plan from a Workbook (the `<work-component>` graph, via
  Workbooks.Workbook.tangle_plan) and compile each component's source block to a
  WASM command/component, content-addressed in build/cache.

  ── The canon (wb-fm0): untrusted source NEVER compiles or runs natively ──────
  Every language lane compiles + runs untrusted user source ENTIRELY in the wasm
  sandbox (wasmtime), zero native compilation:
    * C      → clang.wasm + wasm-ld            (Compilers.compile_c)       fm0.1
    * Zig    → zig1.wasm → clang.wasm          (Compilers.zig_compile…)    fm0.2
    * Rust   → mrustc.wasm → clang.wasm + std  (Compilers.rust_compile…)   fm0.3
    * JS     → QuickJS-ng built by clang.wasm  (Compilers.js_compile…)     fm0.4
    * Go     → yaegi interpreter (yaegi-run.wasm)                          fm0.5
    * TS     → tsc inside QuickJS → JS lane    (Compilers.ts_compile…)     fm0.6
  The compiler/interpreter wasms themselves are built ONCE by native toolchains
  (trusted provisioning: build.sh / provision-rust.sh) — those build only the
  trusted tools, never user code. A lane with external deps (cargo/npm/go-modules)
  returns `{:error, {*_unsupported_in_sandbox, _}}` rather than falling back to native.

  ── Remaining native tools — NOT in the untrusted-source path ─────────────────
  The Component-Model composition path (used only by host/demos/build.ex, not the
  core stdin/stdout dataflow) keeps two native tools, neither of which compiles
  untrusted source:
    * `wac` (compose/plug) — composes already-built, validated TRUSTED components;
      stays native because its tokio dep won't target wasi. Byte manipulation only.
    * `jco`/componentize-js (typed JS components) — the one HONEST BLOCKER (fm0.7):
      it runs StarlingMonkey (a JS engine) + wizer under Node to pre-init the JS,
      which can't be a wasmtime guest. See `build_engine_js`.
  `wasm-tools` (component new / validate) now runs IN the sandbox via wasm-tools.wasm
  (fm0.8). The old native build isolator `Workbooks.Sandbox` (bwrap/sandbox-exec) was
  DELETED (wb-9ja): with every untrusted compile in-wasm, there is no native compile
  to isolate. The wasm sandbox (wasmtime) IS the boundary now.
  """

  alias Workbooks.PackageManager.{Paths, Build, Run, Compose}

  @doc "The content-addressed commands store dir (build/commands/)."
  def commands_dir, do: Paths.commands()

  # ── content-address (Workbooks.PackageManager.Paths) ───────────────────────
  # cache_key + content_address are the shared content-address primitives; they
  # live in Paths so the Build / Run / Compose lanes share one home. These delegate
  # the public surface unchanged.
  defdelegate content_address(wasm_path), to: Paths
  defdelegate cache_key(parts), to: Paths

  # ── build / resolve lanes (Workbooks.PackageManager.Build) ─────────────────
  # Every untrusted-source compile (C/Zig/Rust/JS/TS/Go/Svelte + npm/cargo dep
  # pipelines) lives in the Build sibling; these delegate the public surface so
  # every existing caller (`PackageManager.build/…`, build_dir, build_c_dir,
  # tangle, parse_package_json_deps) is unchanged.
  defdelegate tangle(org), to: Build
  defdelegate build(comp), to: Build
  defdelegate build_dir(dir, lang), to: Build
  defdelegate build_c_dir(abs, extra_argv), to: Build
  defdelegate build_c_dir(abs, extra_argv, include_only), to: Build
  defdelegate build_c_dir(abs, extra_argv, include_only, compile_only), to: Build
  defdelegate parse_package_json_deps(dir), to: Build

  @doc "Componentize a JS Workbook into a WIT-typed Component (see Compose) — jco native (wb-fm0.7)."
  defdelegate build_engine_js(src), to: Compose
  defdelegate build_engine_js(src, world_wit), to: Compose

  @doc "Node-style JS Workbook → WIT-typed Component (Node-compat preamble + jco) — see Compose."
  defdelegate build_node_js(src), to: Compose
  defdelegate build_node_js(src, world_wit), to: Compose

  # ── run lane (Workbooks.PackageManager.Run) ────────────────────────────────
  # The wasmtime-CLI run path (DoS bounds, JsDock detour, Go-source detour,
  # streaming Port) lives in the Run sibling; these delegate the public surface
  # so every existing caller (`PackageManager.run/…`, run_streaming, capture_help,
  # wasmtime_cache_args/flags) is unchanged.
  defdelegate capture_help(wasm_path), to: Run
  defdelegate capture_help(wasm_path, flag), to: Run
  defdelegate wasmtime_cache_args(), to: Run
  defdelegate wasmtime_cache_flags(), to: Run
  defdelegate run(wasm_path, input), to: Run
  defdelegate run(wasm_path, input, argv), to: Run
  defdelegate run(wasm_path, input, argv, dirs), to: Run
  defdelegate run(wasm_path, input, argv, dirs, opts), to: Run
  defdelegate run_streaming(wasm_path, argv), to: Run
  defdelegate run_streaming(wasm_path, argv, dirs), to: Run
  defdelegate run_streaming(wasm_path, argv, dirs, opts), to: Run
  defdelegate cleanup_streaming(meta), to: Run

  @doc """
  Execute a Workbook's DAG: build each component, run them in topological order,
  and pipe each one's stdout into its consumer's stdin along the work-component `out`→`in`
  edges. Host-orchestrated dataflow — composes stdin/stdout filters (stock Javy,
  any language) without WIT. Typed in-WASM composition (wac plug) is the upgrade,
  and needs WIT-declared components (jco / cargo-component). Returns name → output.
  """
  def run_dag(org, input) do
    Workbooks.Workbook.tangle_plan(org) |> Map.get("worlds") |> hd() |> run_world(input)
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

  # ── component-model composition (Workbooks.PackageManager.Compose) ─────────
  # componentize (core → component, wasm-tools in-sandbox), structural `compose`
  # (wac), and the typed dataflow path (jco componentize + wac plug) live in the
  # Compose sibling; these delegate the public surface unchanged.
  defdelegate componentize(core_wasm), to: Compose
  defdelegate compose(components), to: Compose
  defdelegate typed_compose(org), to: Compose
  defdelegate componentize_typed(src, wit, world), to: Compose
  defdelegate validate_component(path), to: Compose
end
