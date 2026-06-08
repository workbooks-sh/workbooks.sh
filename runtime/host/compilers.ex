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

  # ── Rust full-std lane (wb-fm0.3) ──────────────────────────────────────────
  # Recipe + walls: compilers/rust/{PORT-LOG.org,BUILD-STATE.org,std/std-e2e.sh}.
  @rust_clang_flags ~w(--target=wasm32-wasip1 --sysroot=/usr -O1 -fno-strict-aliasing -w
                       -fwasm-exceptions -mllvm -wasm-enable-sjlj -mllvm -wasm-use-legacy-eh=false
                       -Xclang -disable-llvm-verifier)

  @doc """
  Compile untrusted Rust (full std) → a runnable wasm ARTIFACT entirely in the sandbox:
  mrustc.wasm (.rs → C) → clang.wasm (C → .o) → wasm-ld (link against the libstd that was
  prebuilt BY mrustc.wasm, plus wasi_shim + the _Unwind_Resume stub) — zero native execution.

  Requires the one-time libstd prebuild (compilers/rust/std/prebuild-libstd.sh, driven by
  provision-rust.sh). If it's absent this returns {:error, {:libstd_not_prebuilt, dir}} rather
  than silently shelling a native rustc — the canon is no native compile for untrusted source.
  Returns {:ok, wasm_path, log} | {:error, reason}.
  """
  def rust_compile_to_wasm(source_path, opts \\ [], root \\ default_root()) do
    rd = Path.join(root, "rust")
    mrdir = Path.expand(Path.join(rd, "mrustc-root/mrustc"))
    mrwasm = Path.expand(Path.join(rd, "mrustc-root/mrustc_std.wasm"))
    clang = Path.expand(Path.join([root, "clang", "clang-root", "llvm.core.wasm"]))
    csys = Path.expand(Path.join([root, "clang", "clang-root", "sysroot"]))
    shim_src = Path.expand(Path.join([root, "zig", "wasi_shim.c"]))
    ustub_src = Path.expand(Path.join([rd, "std", "ustub.c"]))
    o = Path.join(mrdir, "output-wasi")

    cond do
      not File.regular?(mrwasm) -> {:error, {:mrustc_not_built, mrwasm}}
      not File.regular?(clang) -> {:error, {:clang_not_built, clang}}
      not File.regular?(Path.join(o, "libstd.rlib.o")) -> {:error, {:libstd_not_prebuilt, o}}
      true -> do_rust_compile(source_path, mrdir, mrwasm, clang, csys, o, shim_src, ustub_src, opts)
    end
  end

  defp do_rust_compile(source_path, mrdir, mrwasm, clang, csys, o, shim_src, ustub_src, opts) do
    id = Integer.to_string(:erlang.unique_integer([:positive]))
    name = "wbr#{id}"
    File.mkdir_p!(Path.join(mrdir, ".mrtmp"))
    File.mkdir_p!(Path.join(mrdir, ".cctmp"))
    File.cp!(Path.expand(source_path), Path.join(o, "#{name}.rs"))

    mr = fn args ->
      wasmtime(
        ["-W", "exceptions=y", "-W", "max-wasm-stack=134217728",
         "--env", "MRUSTC_TARGET_VER=1.54", "--env", "STD_ENV_ARCH=wasm32", "--env", "TMPDIR=/tmp",
         "--dir", "#{mrdir}::.", "--dir", "#{mrdir}/.mrtmp::/tmp", mrwasm | args]
      )
    end

    cl = fn args ->
      wasmtime(
        ["-W", "exceptions=y", "--dir", "#{csys}::/usr", "--dir", "#{mrdir}::/work",
         "--dir", "#{mrdir}/.cctmp::/tmp", "--env", "TMPDIR=/tmp", clang | args]
      )
    end

    # shared shim + unwind-stub objects (compile once, reused across compiles)
    ensure_rust_obj(o, "wasi_shim", shim_src, cl)
    ensure_rust_obj(o, "ustub", ustub_src, cl)

    # wb-3s8/wb-6lh: fetch + compile each declared crates.io dependency (pure-Rust, in-sandbox)
    # into output-wasi/deps/, returning {extern_args, dep_object_paths}. Errors short-circuit.
    case ensure_deps(Keyword.get(opts, :deps, []), mrdir, o, mr, cl) do
      {:error, _} = depserr ->
        for ext <- ~w(rs c o hir wasm), do: File.rm(Path.join(o, "#{name}.#{ext}"))
        depserr

      {:ok, extern_args, dep_objs} ->
        ldirs = if dep_objs == [], do: [], else: ["-L", "output-wasi/deps"]

        log1 =
          mr.(["output-wasi/#{name}.rs", "--crate-name", name, "--crate-type", "bin",
               "-L", "output-wasi"] ++ ldirs ++ extern_args ++
              ["--out-dir", "output-wasi", "--target", "wasm32-wasi", "--edition", "2018"])

        result =
          if File.regular?(Path.join(o, "#{name}.c")) do
            cl.(["clang"] ++ @rust_clang_flags ++ ["-c", "/work/output-wasi/#{name}.c", "-o", "/work/output-wasi/#{name}.o"])

            if File.regular?(Path.join(o, "#{name}.o")) do
              libstd = Path.wildcard(Path.join(o, "*.rlib.o")) |> Enum.map(&"/work/output-wasi/#{Path.basename(&1)}")

              ld =
                ["wasm-ld", "-m", "wasm32", "-L/usr/lib/wasm32-unknown-wasip1", "-L/usr/lib/wasm32-wasip1",
                 "/usr/lib/wasm32-wasip1/crt1-command.o", "/work/output-wasi/#{name}.o"] ++
                  dep_objs ++ libstd ++
                  ["/work/output-wasi/wasi_shim.o", "/work/output-wasi/ustub.o",
                   "-lc", "-lsetjmp", "/usr/lib/wasm32-unknown-wasip1/libclang_rt.builtins.a",
                   "-o", "/work/output-wasi/#{name}.wasm"]

              log2 = cl.(ld)
              outw = Path.join(o, "#{name}.wasm")

              if File.regular?(outw) do
                dest = Path.join(System.tmp_dir!(), "wbrust-#{id}.wasm")
                File.cp!(outw, dest)
                {:ok, dest, {log1, log2}}
              else
                {:error, {:link_failed, log2}}
              end
            else
              {:error, {:cc_failed, log1}}
            end
          else
            {:error, {:rustc_failed, log1}}
          end

        # clean this job's transient files (keep shared libstd/shim/ustub + cached deps)
        for ext <- ~w(rs c o hir wasm), do: File.rm(Path.join(o, "#{name}.#{ext}"))
        File.rm(Path.join(o, "lib#{name}.rlib"))
        result
    end
  end

  # ── crates.io dependency support (wb-3s8 / wb-6lh) ──────────────────────────
  # Each dep: %{name, version} | {name, version} | "name@version". Fetched from the static
  # CDN, compiled (with its default features) via mrustc.wasm→clang.wasm into output-wasi/deps/,
  # cached by name+version. Returns {:ok, extern_args, dep_object_guest_paths} | {:error, _}.
  # Pure-Rust only (no proc-macros / build.rs / transitive deps yet — the next slices).
  defp ensure_deps([], _mrdir, _o, _mr, _cl), do: {:ok, [], []}

  defp ensure_deps(deps, mrdir, o, mr, cl) do
    File.mkdir_p!(Path.join(o, "deps"))

    Enum.reduce_while(deps, {:ok, [], []}, fn dep, {:ok, externs, objs} ->
      {name, version} = parse_dep(dep)

      case compile_dep(name, version, mrdir, o, mr, cl) do
        {:ok, rlib_rel, obj_guest} ->
          {:cont, {:ok, externs ++ ["--extern", "#{name}=#{rlib_rel}"], objs ++ [obj_guest]}}

        {:error, _} = e ->
          {:halt, e}
      end
    end)
  end

  defp parse_dep(%{name: n, version: v}), do: {n, v}
  defp parse_dep({n, v}), do: {to_string(n), to_string(v)}
  defp parse_dep(s) when is_binary(s), do: (case String.split(s, "@", parts: 2) do
    [n, v] -> {n, v}
    [n] -> {n, "*"}
  end)

  defp compile_dep(name, version, mrdir, o, mr, cl) do
    rlib_rel = "output-wasi/deps/lib#{name}.rlib"
    obj_host = Path.join(o, "deps/lib#{name}.rlib.o")
    obj_guest = "/work/output-wasi/deps/lib#{name}.rlib.o"

    if File.regular?(obj_host) do
      {:ok, rlib_rel, obj_guest}
    else
      with {:ok, lib_rs, features, edition} <- fetch_crate(name, version, Path.join(o, "deps")) do
        rel_src = "output-wasi/deps/#{name}.rs"
        File.cp!(lib_rs, Path.join(mrdir, rel_src))
        cfgs = Enum.flat_map(features, fn f -> ["--cfg", ~s|feature="#{f}"|] end)

        mr.([rel_src, "--crate-name", name, "--crate-type", "rlib", "-o", rlib_rel,
             "-L", "output-wasi", "-L", "output-wasi/deps", "--out-dir", "output-wasi/deps",
             "--target", "wasm32-wasi", "--edition", edition] ++ cfgs)

        c = Path.join(o, "deps/lib#{name}.rlib.c")

        if File.regular?(c) do
          cl.(["clang"] ++ @rust_clang_flags ++ ["-c", "/work/output-wasi/deps/lib#{name}.rlib.c", "-o", obj_guest])
          if File.regular?(obj_host), do: {:ok, rlib_rel, obj_guest}, else: {:error, {:dep_cc_failed, name}}
        else
          {:error, {:dep_compile_failed, name}}
        end
      end
    end
  end

  # Fetch + extract a crate from the static CDN; return {:ok, lib_rs_path, default_features, edition}.
  defp fetch_crate(name, version, into_dir) do
    File.mkdir_p!(into_dir)
    url = "https://static.crates.io/crates/#{name}/#{name}-#{version}.crate"
    tarball = Path.join(into_dir, "#{name}-#{version}.crate")

    with {_, 0} <- System.cmd("curl", ["-fsSL", url, "-o", tarball], stderr_to_stdout: true),
         {_, 0} <- System.cmd("tar", ["-xzf", tarball, "-C", into_dir], stderr_to_stdout: true) do
      cdir = Path.join(into_dir, "#{name}-#{version}")
      lib_rs = Enum.find([Path.join(cdir, "src/lib.rs"), Path.join(cdir, "lib.rs")], &File.regular?/1)
      cargo = Path.join(cdir, "Cargo.toml")

      cond do
        is_nil(lib_rs) -> {:error, {:no_lib_rs, name}}
        true -> {:ok, lib_rs, default_features(cargo), crate_edition(cargo)}
      end
    else
      {out, _} -> {:error, {:fetch_failed, name, version, String.slice(to_string(out), 0, 200)}}
    end
  end

  # Parse the [features] default = [...] list from Cargo.toml (the enabled-by-default features).
  defp default_features(cargo) do
    with {:ok, body} <- File.read(cargo),
         [_, list] <- Regex.run(~r/^\s*default\s*=\s*\[([^\]]*)\]/m, body) do
      Regex.scan(~r/"([^"]+)"/, list) |> Enum.map(fn [_, f] -> f end)
    else
      _ -> []
    end
  end

  defp crate_edition(cargo) do
    with {:ok, body} <- File.read(cargo),
         [_, e] <- Regex.run(~r/^\s*edition\s*=\s*"(\d+)"/m, body) do
      e
    else
      _ -> "2015"
    end
  end

  # Compile a shared support object (wasi_shim/ustub) into output-wasi once; reused by every
  # Rust compile. Plain C, no -disable-verifier needed (these aren't mrustc-emitted).
  defp ensure_rust_obj(o, name, src, cl) do
    obj = Path.join(o, "#{name}.o")

    unless File.regular?(obj) do
      File.cp!(src, Path.join(o, "#{name}.c"))
      cl.(["clang", "--target=wasm32-wasip1", "--sysroot=/usr", "-O1", "-w",
           "-c", "/work/output-wasi/#{name}.c", "-o", "/work/output-wasi/#{name}.o"])
    end
  end

  # Run `wasmtime run <args>` and return its combined output (the sandbox executor).
  defp wasmtime(args) do
    {out, _} = System.cmd("wasmtime", ["run" | args], stderr_to_stdout: true)
    out
  end

  # ── JS full lane (wb-fm0.4) ────────────────────────────────────────────────
  # Untrusted JS compiles AND runs entirely in the sandbox via QuickJS-ng built to wasm by
  # clang.wasm (no JIT, no native javy). The wb harness (compilers/js/harness.c) supplies the
  # same contract the native-javy lane did — Javy.IO.readSync/writeSync + console — plus a
  # TextEncoder/Decoder polyfill. Recipe: compilers/js/build.sh.
  @js_qobjs ~w(quickjs cutils libregexp libunicode xsum)

  @doc """
  Compile JS source → a runnable wasm command entirely in the sandbox: embed the JS into a C
  byte array (js_src.c), clang.wasm-compile it, and wasm-ld it with the prebuilt harness +
  libquickjs objects. Self-heals the toolchain (compilers/js/build.sh) if the objects are
  absent. Returns {:ok, wasm_path, log} | {:error, reason}.
  """
  def js_compile_to_wasm(source_path, _opts \\ [], root \\ default_root()) do
    jd = Path.join(root, "js")
    clang = Path.expand(Path.join([root, "clang", "clang-root", "llvm.core.wasm"]))
    csys = Path.expand(Path.join([root, "clang", "clang-root", "sysroot"]))
    qsrc = Path.expand(Path.join(jd, "qjs-root/quickjs-ng"))
    harness = Path.expand(Path.join(jd, "harness.o"))
    libobjs = Enum.map(@js_qobjs, &Path.join(qsrc, "#{&1}.o"))

    have_toolchain? = File.regular?(harness) and Enum.all?(libobjs, &File.regular?/1)

    cond do
      not File.regular?(clang) ->
        {:error, {:clang_not_built, clang}}

      not have_toolchain? ->
        # one-time self-heal: build the QuickJS objects + harness in-sandbox
        wasmtime_build_js(jd)

        if File.regular?(harness) and Enum.all?(libobjs, &File.regular?/1),
          do: do_js_compile(source_path, clang, csys, harness, libobjs),
          else: {:error, {:js_toolchain_missing, jd}}

      true ->
        do_js_compile(source_path, clang, csys, harness, libobjs)
    end
  end

  defp wasmtime_build_js(jd) do
    System.cmd("bash", [Path.expand(Path.join(jd, "build.sh"))], stderr_to_stdout: true)
  end

  defp do_js_compile(source_path, clang, csys, harness, libobjs) do
    id = Integer.to_string(:erlang.unique_integer([:positive]))
    job = Path.join(System.tmp_dir!(), "wbjs-#{id}")
    File.mkdir_p!(Path.join(job, "tmp"))
    File.write!(Path.join(job, "js_src.c"), js_src_c(File.read!(Path.expand(source_path))))
    File.cp!(harness, Path.join(job, "harness.o"))
    for o <- libobjs, do: File.cp!(o, Path.join(job, Path.basename(o)))

    cl = fn args ->
      wasmtime(["-W", "exceptions=y", "--dir", "#{csys}::/usr", "--dir", "#{job}::/work",
                "--dir", "#{job}/tmp::/tmp", "--env", "TMPDIR=/tmp", clang | args])
    end

    log1 = cl.(["clang", "--target=wasm32-wasip1", "--sysroot=/usr", "-O2", "-w", "-c", "/work/js_src.c", "-o", "/work/js_src.o"])

    result =
      if File.regular?(Path.join(job, "js_src.o")) do
        objs = (["harness.o", "js_src.o"] ++ Enum.map(@js_qobjs, &"#{&1}.o")) |> Enum.map(&"/work/#{&1}")

        ld =
          ["wasm-ld", "-m", "wasm32", "-L/usr/lib/wasm32-unknown-wasip1", "-L/usr/lib/wasm32-wasip1",
           "/usr/lib/wasm32-wasip1/crt1-command.o"] ++
            objs ++
            ["-lc", "/usr/lib/wasm32-unknown-wasip1/libclang_rt.builtins.a", "-o", "/work/out.wasm"]

        log2 = cl.(ld)
        outw = Path.join(job, "out.wasm")

        if File.regular?(outw) do
          dest = Path.join(System.tmp_dir!(), "wbjs-#{id}.wasm")
          File.cp!(outw, dest)
          {:ok, dest, {log1, log2}}
        else
          {:error, {:link_failed, log2}}
        end
      else
        {:error, {:cc_failed, log1}}
      end

    File.rm_rf(job)
    result
  end

  # Embed JS bytes as a C byte array the harness evals (wb_js_src/wb_js_len).
  defp js_src_c(src) do
    bytes = src |> :binary.bin_to_list() |> Enum.join(",")
    "const char wb_js_src[]={#{bytes}#{if(byte_size(src) > 0, do: ",", else: "")}0};\nconst unsigned wb_js_len=#{byte_size(src)};\n"
  end

  # ── TypeScript lane (wb-fm0.6) ─────────────────────────────────────────────
  # TS = transpile TS→JS in-sandbox (the real `tsc` running inside QuickJS via qjs-run.wasm),
  # then the JS lane. Zero native execution — no bun/esbuild/swc. Type-strip only
  # (ts.transpileModule), which is what a workbook component needs.
  @doc """
  Compile TypeScript → a runnable wasm command entirely in the sandbox: run the TypeScript
  compiler (typescript.js) inside qjs-run.wasm to transpile TS→JS, then compile that JS via
  the QuickJS JS lane. Self-heals the toolchain (build.sh) if absent. Returns
  {:ok, wasm_path, log} | {:error, reason}.
  """
  def ts_compile_to_wasm(source_path, opts \\ [], root \\ default_root()) do
    jd = Path.join(root, "js")
    qrun = Path.expand(Path.join(jd, "qjs-run.wasm"))
    tsjob = Path.expand(Path.join(jd, "ts/tsjob.js"))

    unless File.regular?(qrun) and File.regular?(tsjob), do: wasmtime_build_js(jd)

    cond do
      not (File.regular?(qrun) and File.regular?(tsjob)) ->
        {:error, {:ts_toolchain_missing, jd}}

      true ->
        case ts_transpile(File.read!(Path.expand(source_path)), qrun, tsjob) do
          {:ok, js} ->
            tmp = Path.join(System.tmp_dir!(), "wbts-#{:erlang.unique_integer([:positive])}.js")
            File.write!(tmp, js)
            r = js_compile_to_wasm(tmp, opts, root)
            File.rm(tmp)
            r

          err ->
            err
        end
    end
  end

  # Run tsc (typescript.js) inside qjs-run.wasm: TS on stdin → JS on stdout. The compiler runs
  # ENTIRELY in the sandbox (QuickJS under wasmtime). Returns {:ok, js} | {:error, reason}.
  defp ts_transpile(ts_src, qrun, tsjob) do
    jobdir = Path.dirname(tsjob)
    id = Integer.to_string(:erlang.unique_integer([:positive]))
    tin = Path.join(System.tmp_dir!(), "wbts-in-#{id}.ts")
    terr = Path.join(System.tmp_dir!(), "wbts-err-#{id}.txt")
    File.write!(tin, ts_src)

    cmd =
      "wasmtime run -W exceptions=y -W max-wasm-stack=134217728 " <>
        "--dir #{esc(jobdir)}::/w #{esc(qrun)} /w/tsjob.js < #{esc(tin)} 2> #{esc(terr)}"

    try do
      {out, _status} = System.cmd("sh", ["-c", cmd], stderr_to_stdout: false)

      cond do
        String.trim(out) != "" -> {:ok, out}
        true -> {:error, {:ts_transpile_failed, String.slice(File.read!(terr), 0, 600)}}
      end
    after
      File.rm(tin)
      File.rm(terr)
    end
  end

  defp esc(s), do: "'" <> String.replace(to_string(s), "'", "'\\''") <> "'"

  defp kw(file, key) do
    with {:ok, body} <- File.read(file),
         [_, v] <- Regex.run(~r/^#\+#{key}:\s*(.+)$/m, body) do
      String.trim(v)
    else
      _ -> nil
    end
  end
end
