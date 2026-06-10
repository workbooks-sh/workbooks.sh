defmodule Workbooks.Build do
  @moduledoc """
  The tangle build step — source components → WASM — as part of pack/unpack.

  A workbook RUNS WebAssembly, not source. So packing a buildable workbook has a
  compile stage: each component's source (a Rust crate, a standalone `.rs`, …) is
  built to a `.wasm`, and it's the `.wasm` that ships in the runnable artifact.
  The build INPUTS (source, `target/`, `Cargo.lock`) are scaffolding — they
  belong on the SOURCE rail (GitHub) and in an archive, but NOT in the runnable
  HTML. That's the "build files don't make it into the HTML unless they're
  WebAssembly" rule, made concrete: three projections of the same workbook —

    * runnable  → the `.wasm` outputs (what executes, in the Dock / WASM sandbox)
    * source    → the source inputs (what a human reads + diffs on GitHub)
    * archive   → both

  REAL, not stubbed, and NATIVE-FREE (wb-9ja): every compile routes through the
  in-sandbox wasm lanes (Workbooks.PackageManager / Compilers — mrustc.wasm →
  clang.wasm for Rust, etc.), never a native toolchain. The old native fallbacks
  (`cargo component`, `rustc --target wasm32-*`, `bun/npm run build`) are removed.
  A component whose lane has no in-sandbox path (e.g. a full JS framework `run
  build`) is returned UNBUILT with an honest reason — never faked, never shelled
  out natively. Same builder runs locally and in a cloud engine; the output `.wasm`
  is what the Wasmex Instance loads either way.
  """

  @wasm_magic <<0x00, 0x61, 0x73, 0x6D>>

  @doc """
  Build every buildable component found under `dir`. Returns
  %{built: [%{name, rel, bytes}], unbuilt: [%{name, reason}]}. `bytes` is the
  compiled `.wasm` (validated by magic number). Best-effort + honest: a missing
  toolchain yields an `unbuilt` entry, not a fake artifact.
  """
  def build(dir, opts \\ []) do
    results = dir |> discover() |> Enum.flat_map(&build_one(&1, dir, opts))

    %{
      built: for({:built, b} <- results, do: b),
      unbuilt: for({:unbuilt, u} <- results, do: u)
    }
  end

  @doc """
  Is this path a build INPUT (source/scaffold that compiles away — keep off the
  runnable artifact)? Covers Rust + the JS/UI frameworks (Svelte/Astro/Solid/
  Preact, etc — their source + node_modules + manifests), since a workbook ships
  compiled output, not source.
  """
  def build_input?(path) do
    base = Path.basename(path)
    String.contains?(path, ["target/", "node_modules/", ".cargo/", "/src/"]) or
      base in ~w(Cargo.toml Cargo.lock package.json package-lock.json bun.lockb pnpm-lock.yaml tsconfig.json vite.config.js svelte.config.js astro.config.mjs) or
      Path.extname(path) in ~w(.rs .jsx .tsx .ts .svelte .astro .vue)
  end

  @doc "Is this path a build OUTPUT (ships to the runnable workbook — .wasm for compute, or a built bundle under dist/build/.output)?"
  def build_output?(path) do
    Path.extname(path) == ".wasm" or String.contains?(path, ["/dist/", "/build/", "/.output/"])
  end

  # ── discover ────────────────────────────────────────────────────────────────
  # A component is a Rust crate (Cargo.toml), a standalone .rs, OR a JS/UI project
  # (a package.json with a `build` script — Svelte/Astro/Solid/Preact/… all look
  # the same here: a project that builds itself). Each returns a LIST of results
  # since one project yields many output files.
  defp discover(dir) do
    crates = (dir |> Path.join("**/Cargo.toml") |> Path.wildcard()) |> Enum.map(&{:crate, Path.dirname(&1)})
    crate_dirs = MapSet.new(crates, fn {:crate, d} -> d end)

    js_projects =
      dir
      |> Path.join("**/package.json")
      |> Path.wildcard()
      |> Enum.reject(&String.contains?(&1, "node_modules/"))
      |> Enum.filter(&has_build_script?/1)
      |> Enum.map(&{:js_project, Path.dirname(&1)})

    loose_rs =
      dir
      |> Path.join("**/*.rs")
      |> Path.wildcard()
      |> Enum.reject(fn f -> Enum.any?(crate_dirs, &String.starts_with?(f, &1)) end)
      |> Enum.map(&{:rs, &1})

    crates ++ loose_rs ++ js_projects
  end

  defp has_build_script?(pkg_json) do
    case Jason.decode(File.read!(pkg_json)) do
      {:ok, %{"scripts" => %{"build" => _}}} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  # ── build one (→ list of results) ────────────────────────────────────────────
  #
  # NO NATIVE COMPILATION (wb-9ja). Untrusted component source is compiled ONLY
  # through the in-sandbox wasm lanes (Workbooks.PackageManager → Compilers:
  # mrustc.wasm → clang.wasm, etc.). The old native fallbacks — `cargo component`,
  # `rustc --target wasm32-*`, and `bun/npm run build` — are DELETED. A lane with
  # no in-sandbox equivalent yields an honest `unbuilt` entry, never a native shell.
  #
  # SUBSTRATE NOTE: the lanes ultimately run `wasmtime` on `.wasm` compilers — that
  # IS the architecture (wasm executed by the native wasmtime host) and is fine. A
  # NATIVE language toolchain binary (cargo/rustc/bun/npm) is what's banned.
  defp build_one({:crate, crate_dir}, root, _opts) do
    name = Path.relative_to(crate_dir, root)

    # A Rust crate dir compiles in-sandbox via the rust lane (its Cargo.toml deps
    # are parsed + fetched + compiled in-sandbox; the native cargo path is gone).
    case Workbooks.PackageManager.build_dir(crate_dir, "rust") do
      {:ok, wasm, _} -> [emit_wasm(name, wasm)]
      {:error, reason} -> [{:unbuilt, %{name: name, reason: "rust lane: #{inspect(reason)}"}}]
    end
  end

  defp build_one({:rs, src}, root, _opts) do
    name = Path.relative_to(src, root)

    # A lone .rs compiles in-sandbox via the rust lane (mrustc.wasm → clang.wasm).
    case Workbooks.Compilers.rust_compile_to_wasm(src) do
      {:ok, wasm, _logs} -> [emit_wasm(name, wasm)]
      {:error, reason} -> [{:unbuilt, %{name: name, reason: "rust lane: #{inspect(reason)}"}}]
    end
  end

  # A JS/UI project (Svelte/Astro/Solid/…) builds via its OWN node toolchain
  # (`bun/npm run build` + a framework's vite/rollup). That is NATIVE execution of
  # an untrusted project's build scripts — banned (wb-9ja), and there is no
  # in-sandbox equivalent for a full framework dev-server build here. Honest
  # unbuilt: the JS WASM lanes (PackageManager js/ts/svelte) cover single-entry
  # bundles; a whole framework `run build` does not move in-sandbox yet.
  defp build_one({:js_project, dir}, root, _opts) do
    name = Path.relative_to(dir, root)
    [{:unbuilt, %{name: name, reason: "lane_unavailable: native JS framework build (bun/npm run build) removed — no in-sandbox lane for a full framework build (wb-9ja)"}}]
  end

  defp emit_wasm(name, wasm_path) do
    bytes = File.read!(wasm_path)

    case bytes do
      <<@wasm_magic, _::binary>> -> {:built, %{name: name, rel: Path.basename(wasm_path), bytes: bytes}}
      _ -> {:unbuilt, %{name: name, reason: "output is not valid wasm (bad magic)"}}
    end
  end
end
