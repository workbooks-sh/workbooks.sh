defmodule Workbooks.Compilers do
  @moduledoc """
  Compiler-in-WASM framework (wb-cwasm). A compiler lives in runtime/compilers/<lang>/
  (a build recipe + source/stubs). `build/1` compiles it to a wasm command; source is
  then compiled+run ENTIRELY in the sandbox — zero native execution — making untrusted
  compiled-language source as safe as running an interpreter (unlike a NATIVE compile
  under bwrap, which is not an untrusted-source boundary). See docs/COMPILER-IN-WASM.org.

  Reuses the command path (CommandRegistry + PackageManager.run, which enables
  -W exceptions + memory64). Two compiler KINDs:
    * compile-and-run — the compiler reads source and executes it (e.g. c4). `compile_run/4`.
    * compile-to-wasm — the compiler emits an artifact .wasm we then run (tcc/zig/rustc).
      Lands with its first tenant in P1 (no stub before there's a real one to test).
  """
  alias Workbooks.CommandRegistry

  @doc "Discovery root for compilers/<lang>/."
  def default_root do
    Enum.find(["compilers", "runtime/compilers", Path.expand("compilers", File.cwd!())], &File.dir?/1) ||
      "compilers"
  end

  @doc "Languages with a compilers/<lang>/manifest.org."
  def list(root \\ default_root()) do
    Path.wildcard(Path.join([root, "*", "manifest.org"]))
    |> Enum.map(&Path.basename(Path.dirname(&1)))
    |> Enum.sort()
  end

  @doc """
  Build a language's compiler from compilers/<lang>/ → a registered wasm command.
  Returns {:ok, cli, wasm_path} | {:error, reason}.
  """
  def build(lang, root \\ default_root()) do
    dir = Path.join(root, lang)
    manifest = Path.join(dir, "manifest.org")
    cli = kw(manifest, "CLI_BIN")
    script = Path.join(dir, kw(manifest, "BUILD") || "build.sh")
    mode = if kw(manifest, "ARG_MODE") == "stdin1", do: :stdin1, else: :argv

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

  @doc """
  Compile + run source through a COMPILE-AND-RUN compiler (e.g. c4): the compiler reads
  the source file and executes it, entirely in the sandbox. The source's dir is the only
  preopen (untrusted source can't reach the host). Returns {:ok, output} | {:error, _}.
  """
  def compile_run(lang, source_path, argv \\ [], root \\ default_root()) do
    cli = kw(Path.join([root, lang, "manifest.org"]), "CLI_BIN")
    src = Path.expand(source_path)
    dir = Path.dirname(src)
    CommandRegistry.run(cli, "", argv ++ ["/src/#{Path.basename(src)}"], ["#{dir}::/src"])
  end

  defp kw(file, key) do
    with {:ok, body} <- File.read(file),
         [_, v] <- Regex.run(~r/^#\+#{key}:\s*(.+)$/m, body) do
      String.trim(v)
    else
      _ -> nil
    end
  end
end
