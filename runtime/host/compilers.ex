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
        # self-heal: ensure the compiler command (e.g. zig1) is registered. Without this
        # the first compile after a fresh boot fails {:unknown_command, cli} (the lib is on
        # disk but the wasm command was never registered this run). Idempotent — build/2
        # content-addresses, so a re-register is a no-op. Mirrors compile_c's clang heal.
        unless cli in CommandRegistry.list(), do: build(lang, root)

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

  # clang/lld (YoWASP LLVM-for-wasi) link paths inside the mounted sysroot (/usr).
  @clang_lib_rt "/usr/lib/wasm32-unknown-wasip1"
  @clang_lib_c "/usr/lib/wasm32-wasip1"

  @doc """
  Compile + LINK C source to a RUNNABLE wasm with clang+lld, entirely in the sandbox
  (zero native execution). Two in-sandbox stages: `clang -c` then `wasm-ld` — the clang
  driver can't spawn the linker under WASI, so we run them as separate llvm.core.wasm
  invocations (the same multitool, dispatched by argv). Returns {:ok, wasm_path, logs}.

  This is the production full-C compiler-in-wasm (clang 22, libc) — unlike c4's interpreted
  C subset. opts: `:argv` (extra clang flags), `:includes` ([{host_dir, guest_dir}] extra
  header roots, e.g. zig.h for the Zig chain), `:extra_csrc` (more .c sources compiled +
  linked alongside the main one), `:ld_args` (extra wasm-ld link flags, e.g. `--wrap=mmap`
  for the mmap shim), `:crt` (link crt1, default true), `:run_opts`.
  """
  def compile_c(source_path, opts \\ [], root \\ default_root()) do
    m = Path.join([root, "clang", "manifest.org"])
    cli = kw(m, "CLI_BIN") || "clang"
    sysroot = Path.expand(Path.join([root, "clang", kw(m, "SYSROOT") || "clang-root/sysroot"]))
    target = Keyword.get(opts, :target, kw(m, "TARGET") || "wasm32-wasip1")
    extra = Keyword.get(opts, :argv, [])
    includes = Keyword.get(opts, :includes, [])

    cond do
      not File.dir?(Path.join(sysroot, "lib")) ->
        {:error, {:not_built, sysroot}}

      true ->
        # ensure the clang multitool command is registered (idempotent)
        if CommandRegistry.run(cli, "", ["--version"]) == {:error, {:unknown_command, cli}},
          do: build("clang", root)

        id = Integer.to_string(:erlang.unique_integer([:positive]))
        job = Path.join(System.tmp_dir!(), "clangjob-#{id}")
        File.mkdir_p!(Path.join(job, "tmp"))
        ext = Path.extname(source_path)
        srcname = "src" <> if(ext == "", do: ".c", else: ext)
        File.cp!(Path.expand(source_path), Path.join(job, srcname))

        # extra C sources compiled + linked alongside the main one (e.g. the zig wasi shim)
        extra_csrc = Keyword.get(opts, :extra_csrc, [])

        extra_names =
          extra_csrc
          |> Enum.with_index()
          |> Enum.map(fn {host, i} ->
            nm = "extra#{i}.c"
            File.cp!(Path.expand(host), Path.join(job, nm))
            nm
          end)

        inc = includes |> Enum.with_index() |> Enum.map(fn {{h, _}, i} -> {h, "/inc#{i}"} end)
        inc_flags = Enum.flat_map(inc, fn {_, g} -> ["-I", g] end)

        preopens =
          ["#{sysroot}::/usr", "#{job}::/work", "#{Path.join(job, "tmp")}::/tmp"] ++
            Enum.map(inc, fn {h, g} -> "#{h}::#{g}" end)

        ropts =
          Keyword.merge(
            [fuel: 800_000_000_000, timeout_ms: 180_000, env: ["TMPDIR=/tmp"]],
            Keyword.get(opts, :run_opts, [])
          )

        # compile main + each extra source to its own object (one clang invocation each —
        # the driver can't batch+link under WASI). Collect the produced object guest-paths.
        srcs = [{srcname, "out.o"}] ++ Enum.map(extra_names, &{&1, Path.rootname(&1) <> ".o"})

        logs1 =
          for {sn, on} <- srcs do
            CommandRegistry.run(
              cli,
              "",
              ["clang", "--target=#{target}", "--sysroot=/usr", "-O2"] ++
                inc_flags ++ extra ++ ["-c", "/work/#{sn}", "-o", "/work/#{on}"],
              preopens,
              ropts
            )
          end

        log1 = List.first(logs1)
        objs = Enum.map(srcs, fn {_, on} -> on end)
        all_objs? = Enum.all?(objs, &File.regular?(Path.join(job, &1)))

        result =
          if all_objs? do
            # crt1 provides _start for plain C; a zig C-backend object brings its own _start
            # (and libc init), so the zig chain links with crt: false to avoid a dup _start.
            crt = if Keyword.get(opts, :crt, true), do: ["#{@clang_lib_c}/crt1-command.o"], else: []
            obj_paths = Enum.map(objs, &"/work/#{&1}")

            # opts[:ld_args] are extra wasm-ld flags (e.g. --wrap=mmap for the mmap
            # shim). They must precede the objects/libs so symbol wrapping applies.
            ld_extra = Keyword.get(opts, :ld_args, [])

            c2 =
              ["wasm-ld", "-m", "wasm32", "-L#{@clang_lib_rt}", "-L#{@clang_lib_c}"] ++
                ld_extra ++ crt ++ obj_paths ++
                ["-lc", "#{@clang_lib_rt}/libclang_rt.builtins.a", "-o", "/work/out.wasm"]

            log2 = CommandRegistry.run(cli, "", c2, preopens, ropts)
            outw = Path.join(job, "out.wasm")

            if File.regular?(outw) do
              dest = Path.join(System.tmp_dir!(), "wbc-#{id}.wasm")
              File.cp!(outw, dest)
              {:ok, dest, {log1, log2}}
            else
              {:error, {:link_failed, log2}}
            end
          else
            {:error, {:compile_failed, log1}}
          end

        File.rm_rf(job)
        result
    end
  end

  @doc """
  Compile C → wasm with clang in-sandbox, then RUN the emitted wasm in-sandbox. The whole
  pipeline (compile, link, execute) is zero native execution. Returns {:ok, output}.
  """
  def compile_and_run_c(source_path, run_argv \\ [], opts \\ [], root \\ default_root()) do
    case compile_c(source_path, opts, root) do
      {:ok, wasm, _logs} ->
        out = Workbooks.PackageManager.run(wasm, "", run_argv, [])
        File.rm(wasm)

        case out do
          {:error, _} = e -> e
          s -> {:ok, String.trim(to_string(s))}
        end

      err ->
        err
    end
  end

  @doc """
  Zig → a runnable wasm ARTIFACT, entirely in the sandbox: zig1.wasm compiles .zig → C
  (zero native exec), then clang.wasm compiles+links that C → wasm. Unlike
  `zig_compile_and_run/4` this returns the wasm PATH (does not run it) — the form the
  PackageManager registers/runs as a command. zig.h (zig's C-backend runtime header) is
  supplied from the zig lib via `:includes`. Returns {:ok, wasm_path, logs} | {:error, _}.
  """
  def zig_compile_to_wasm(source_path, opts \\ [], root \\ default_root()) do
    case compile("zig", source_path, opts, root) do
      {:ok, c_source, _log} ->
        cfile = Path.join(System.tmp_dir!(), "zigc-#{:erlang.unique_integer([:positive])}.c")
        # zig's C-backend emits __builtin_return_address/frame_address for stack-trace
        # capture; clang-on-wasm doesn't implement those (non-emscripten). They affect only
        # debug traces, not program logic, so no-op them for the wasm target.
        prelude = """
        #define __builtin_return_address(x) ((void *)0)
        #define __builtin_frame_address(x) ((void *)0)
        #define __builtin_extract_return_addr(x) (x)
        """
        File.write!(cfile, prelude <> c_source)
        zm = Path.join([root, "zig", "manifest.org"])
        zigdir = Path.join(root, "zig")
        ziglib = Path.expand(Path.join([zigdir, kw(zm, "LIB_ROOT") || "zig-root", kw(zm, "ZIG_LIB") || "lib"]))
        shim = Path.expand(Path.join(zigdir, "wasi_shim.c"))

        r =
          compile_c(cfile,
            [includes: [{ziglib, "/ziglib"}], crt: false, extra_csrc: [shim],
             argv: ["-I/ziglib", "-Wno-everything", "-std=c11"]],
            root
          )

        File.rm(cfile)
        r

      err ->
        err
    end
  end

  @doc """
  Zig END-TO-END in the sandbox: compile .zig → wasm (`zig_compile_to_wasm/3`), then run it —
  every stage in wasm, zero native execution. Returns {:ok, output}.
  """
  def zig_compile_and_run(source_path, run_argv \\ [], opts \\ [], root \\ default_root()) do
    case zig_compile_to_wasm(source_path, opts, root) do
      {:ok, wasm, _logs} ->
        out = Workbooks.PackageManager.run(wasm, "", run_argv, [])
        File.rm(wasm)

        case out do
          {:error, _} = e -> e
          s -> {:ok, String.trim(to_string(s))}
        end

      err ->
        err
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
