defmodule Workbooks.Compilers do
  @moduledoc """
  Compiler-in-WASM framework (wb-cwasm). A compiler lives in runtime/compilers/<lang>/
  (a build recipe + source/stubs). `build/1` compiles it to a wasm command; source is
  then compiled+run ENTIRELY in the sandbox — zero native execution — making untrusted
  compiled-language source as safe as running an interpreter (unlike a NATIVE compile
  under bwrap, which is not an untrusted-source boundary). See docs/COMPILER-IN-WASM.org.

  Reuses the command path (CommandRegistry + PackageManager.run, which enables
  -W exceptions + memory64). Three compiler KINDs:
    * compile-and-run — the compiler reads source and executes it (e.g. c4). `compile_run/4`.
    * compile-to-c    — the compiler emits C from source (e.g. zig1.wasm's C backend).
      `compile/4`. The emitted C goes through the C lane (tcc.wasm) → wasm → run; that
      final step is the same in-sandbox C compile P1 productionizes.
    * compile-to-wasm — the compiler emits an artifact .wasm we then run (tcc/rustc).
      Lands with its first tenant (no stub before there's a real one to test).
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

  @doc """
  Compile source through a COMPILE-TO-C compiler (e.g. zig1.wasm): the compiler runs
  ENTIRELY in the sandbox (zero native execution) and emits C. Returns {:ok, c_source,
  log} | {:error, reason}.

  zig under wasmtime resolves every path against ONE preopen, so we stage a per-job dir
  beside the shared lib/ under the compiler's extracted root and preopen that root. The
  job dir holds the (untrusted) source + the zig caches; lib/ is the read side. The job
  is removed after — nothing of the untrusted compile persists in the tree.
  """
  def compile(lang, source_path, opts \\ [], root \\ default_root()) do
    m = Path.join([root, lang, "manifest.org"])
    cli = kw(m, "CLI_BIN")
    base = Path.expand(Path.join([root, lang, kw(m, "LIB_ROOT") || "zig-root"]))
    zlib = kw(m, "ZIG_LIB") || "lib"
    target = Keyword.get(opts, :target, kw(m, "TARGET") || "wasm32-wasi")
    extra = Keyword.get(opts, :argv, [])

    cond do
      cli in [nil, ""] -> {:error, {:no_cli_bin, lang}}
      not File.dir?(Path.join(base, zlib)) -> {:error, {:not_built, base}}
      true ->
        id = Integer.to_string(:erlang.unique_integer([:positive]))
        rel = "jobs/#{id}"
        job = Path.join(base, rel)
        File.mkdir_p!(Path.join(job, "zc"))
        File.mkdir_p!(Path.join(job, "gc"))
        File.cp!(Path.expand(source_path), Path.join(job, "src.zig"))

        argv =
          ~w(build-obj -ofmt=c -OReleaseSmall) ++
            extra ++
            ["--zig-lib-dir", zlib,
             "--cache-dir", "#{rel}/zc", "--global-cache-dir", "#{rel}/gc",
             "--name", "out", "-femit-bin=#{rel}/out.c",
             "-target", target, "-Mroot=#{rel}/src.zig"]

        # A real compiler does FAR more work than a filter: raise fuel + timeout well
        # above the per-command defaults (an adversarial source is still bounded — the
        # timeout traps a runaway compile, the preopen bounds FS reach).
        ropts = Keyword.merge([fuel: 500_000_000_000, timeout_ms: 120_000], Keyword.get(opts, :run_opts, []))
        log = CommandRegistry.run(cli, "", argv, ["#{base}::."], ropts)
        outc = Path.join(job, "out.c")

        result =
          case {File.regular?(outc), log} do
            {true, _} -> {:ok, File.read!(outc), log}
            {false, {:ok, l}} -> {:error, {:compile_failed, l}}
            {false, {:error, _} = e} -> e
            {false, l} -> {:error, {:compile_failed, l}}
          end

        File.rm_rf(job)
        result
    end
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
