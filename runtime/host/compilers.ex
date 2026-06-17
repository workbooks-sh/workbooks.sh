defmodule Workbooks.Compilers do
  @moduledoc """
  Compiler-in-WASM framework (wb-cwasm). A compiler lives in runtime/compilers/<lang>/
  (a build recipe + source/stubs). `build/1` compiles it to a wasm command; source is
  then compiled+run ENTIRELY in the sandbox — zero native execution — making untrusted
  compiled-language source as safe as running an interpreter (unlike a NATIVE compile
  under bwrap, which is not an untrusted-source boundary). See docs/COMPILER-IN-WASM.md.

  Reuses the command path (CommandRegistry + PackageManager.run, which enables
  -W exceptions + memory64). Three compiler KINDs:
    * compile-and-run — the compiler reads source and executes it (e.g. c4). `compile_run/4`.
    * compile-to-c    — the compiler emits C from source (e.g. zig1.wasm's C backend).
      `compile/4`. The emitted C goes through the C lane (tcc.wasm) → wasm → run; that
      final step is the same in-sandbox C compile P1 productionizes.
    * compile-to-wasm — the compiler emits an artifact .wasm we then run (tcc/rustc).
      Lands with its first tenant (no stub before there's a real one to test).

  This module is a THIN FACADE: the per-language lanes live in sibling modules
  (`Workbooks.Compilers.{Native,Rust,Js}`) sharing `Workbooks.Compilers.Shared`. The
  framework primitives (discovery, `build/1`) stay here; everything else delegates so the
  public `Workbooks.Compilers.<fn>` API every caller uses is unchanged.
  """
  alias Workbooks.CommandRegistry
  alias Workbooks.Compilers.{Shared, Native, Rust, Js}

  @doc "Discovery root for compilers/<lang>/."
  defdelegate default_root, to: Shared

  @doc "Languages with a compilers/<lang>/manifest.html."
  def list(root \\ default_root()) do
    Path.wildcard(Path.join([root, "*", "manifest.html"]))
    |> Enum.map(&Path.basename(Path.dirname(&1)))
    |> Enum.sort()
  end

  @doc """
  Build a language's compiler from compilers/<lang>/ → a registered wasm command.
  Returns {:ok, cli, wasm_path} | {:error, reason}.
  """
  def build(lang, root \\ default_root()) do
    dir = Path.join(root, lang)
    manifest = Path.join(dir, "manifest.html")
    cli = Shared.kw(manifest, "CLI_BIN")
    script = Path.join(dir, Shared.kw(manifest, "BUILD") || "build.sh")
    mode = if Shared.kw(manifest, "ARG_MODE") == "stdin1", do: :stdin1, else: :argv

    cond do
      cli in [nil, ""] -> {:error, {:no_cli_bin, lang}}
      not File.regular?(script) -> {:error, {:no_build_script, script}}
      true ->
        case CommandRegistry.build_and_register_script(cli, script, mode) do
          {:ok, wasm} -> {:ok, cli, wasm}
          err -> err
        end
    end
  end

  # ── Native lanes (C / C++ / Zig / threads) — Workbooks.Compilers.Native ─────
  defdelegate compile_run(lang, source_path, argv \\ [], root \\ default_root()), to: Native
  defdelegate compile(lang, source_path, opts \\ [], root \\ default_root()), to: Native
  defdelegate compile_c(source_path, opts \\ [], root \\ default_root()), to: Native
  defdelegate compile_cpp(source_path, opts \\ [], root \\ default_root()), to: Native
  defdelegate compile_threads(source_path, opts \\ [], root \\ default_root()), to: Native
  defdelegate cpp_eh_staged?(root \\ default_root()), to: Native
  defdelegate cpp_eh_args, to: Native
  defdelegate c_compile_to_kernel(source_path, root \\ default_root()), to: Native
  defdelegate compile_and_run_c(source_path, run_argv \\ [], opts \\ [], root \\ default_root()), to: Native
  defdelegate zig_compile_to_wasm(source_path, opts \\ [], root \\ default_root()), to: Native
  defdelegate zig_compile_and_run(source_path, run_argv \\ [], opts \\ [], root \\ default_root()), to: Native

  # ── Rust lane + crates.io machinery — Workbooks.Compilers.Rust ──────────────
  defdelegate rust_compile_to_wasm(source_path, opts \\ [], root \\ default_root()), to: Rust
  defdelegate compile_rust_threads(source_path, opts \\ [], root \\ default_root()), to: Rust

  # ── JS / TS / bundling lanes — Workbooks.Compilers.Js ───────────────────────
  defdelegate js_compile_to_wasm(source_path, opts \\ [], root \\ default_root()), to: Js
  defdelegate ts_compile_to_wasm(source_path, opts \\ [], root \\ default_root()), to: Js
  defdelegate transpile_ts(ts_src, root \\ default_root()), to: Js
  defdelegate bundle_dir(project_dir, entry_rel, opts \\ [], root \\ default_root()), to: Js
  defdelegate esbuild_bundle_dir(project_dir, entry_rel, opts \\ [], root \\ default_root()), to: Js
  defdelegate svelte_bundle_dir(project_dir, entry_rel, opts \\ [], root \\ default_root()), to: Js
end
