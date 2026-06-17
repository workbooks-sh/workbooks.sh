defmodule Workbooks.Compilers.Native do
  @moduledoc """
  The native compiled-language lanes (C / C++ / Zig / threads): compile + LINK source
  to runnable wasm with clang.wasm + wasm-ld, entirely in the sandbox (zero native
  execution). Includes the compile-and-run (c4) + compile-to-C (zig1) kinds and the
  shared-memory pthreads lane. Extracted from the former compilers.ex god-file.
  """
  alias Workbooks.CommandRegistry
  alias Workbooks.Compilers.Shared
  import Shared, only: [kw: 2]

  @clang_lib_rt Shared.clang_lib_rt()
  @clang_lib_c Shared.clang_lib_c()

  @doc """
  Compile + run source through a COMPILE-AND-RUN compiler (e.g. c4): the compiler reads
  the source file and executes it, entirely in the sandbox. The source's dir is the only
  preopen (untrusted source can't reach the host). Returns {:ok, output} | {:error, _}.
  """
  def compile_run(lang, source_path, argv \\ [], root \\ Shared.default_root()) do
    cli = kw(Path.join([root, lang, "manifest.html"]), "CLI_BIN")
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
  def compile(lang, source_path, opts \\ [], root \\ Shared.default_root()) do
    m = Path.join([root, lang, "manifest.html"])
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
        unless cli in CommandRegistry.list(), do: Workbooks.Compilers.build(lang, root)

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

        # An EMPTY out.c is a FAILED compile, not success — zig1 can emit a 0-byte
        # out.c on error (e.g. a std feature its bootstrap C-backend can't lower),
        # which previously slipped through as {:ok, ""} and then link-failed with a
        # misleading "_start undefined". Require non-empty output so zig1's real
        # error surfaces in the log (wb-pkh.10).
        produced? = File.regular?(outc) and File.stat!(outc).size > 0

        result =
          case {produced?, log} do
            {true, _} -> {:ok, File.read!(outc), log}
            {false, {:ok, l}} -> {:error, {:compile_failed, l}}
            {false, {:error, _} = e} -> e
            {false, l} -> {:error, {:compile_failed, l}}
          end

        File.rm_rf(job)
        result
    end
  end

  # ── C++ lane ───────────────────────────────────────────────────────────────
  # EH archives live in the libc/crt dir of the wasm32-wasip1 sysroot (guest path), staged by build.sh.
  @cpp_eh_abi "#{@clang_lib_c}/libc++abi-eh.a"
  @cpp_eh_unwind "#{@clang_lib_c}/libunwind-eh.a"

  @doc """
  Whether the from-source C++ EH runtime (`libc++abi-eh.a`) is staged in the wasm32-wasip1 sysroot. When
  true, C++ can link the standardized wasm-exceptions runtime; when false, only the no-exceptions subset
  links. (`@clang_lib_c` is the GUEST path /usr/lib/…; this checks the HOST sysroot under `root`.)
  """
  def cpp_eh_staged?(root \\ Shared.default_root()) do
    File.regular?(Path.join([root, "clang", "clang-root", "sysroot", "lib", "wasm32-wasip1", "libc++abi-eh.a"]))
  end

  @doc """
  C++ EH link config `{compile_flags, link_libs}` for the NEW standardized wasm EH (`try_table`/`exnref` —
  the only kind wasmtime 45 `-W exceptions=y` runs), linking the from-source EH `libc++abi-eh.a` +
  `libunwind-eh.a` instead of the no-EH `-lc++abi`. ONE home, shared by `compile_cpp` and
  `PackageManager.build_c_dir`, so the exceptions wiring never drifts between the single-file and dir lanes.
  """
  def cpp_eh_args, do: {["-fwasm-exceptions", "-mllvm", "-wasm-use-legacy-eh=false"], ["-lc++", @cpp_eh_abi, @cpp_eh_unwind]}

  @doc """
  Compile + LINK C++ source to a runnable wasm — the C++ sibling of `compile_c/2`. The sysroot already ships
  libc++ + libc++abi (wasm32-wasip1); this wires them in (`-x c++`, `-std=<std>`, `-lc++ -lc++abi`) so the full
  STL + RTTI (dynamic_cast/typeid) + virtual dispatch + new/delete work in-sandbox.

  NOTE — exceptions: the DEFAULT build is `-fno-exceptions` against the vendored NO-EXCEPTIONS libc++abi.
  Pass `exceptions: true` to compile + link with the new STANDARDIZED wasm EH (`try_table`/`exnref`, the only
  kind wasmtime 45 `-W exceptions=y` runs): the source builds `-fwasm-exceptions -mllvm -wasm-use-legacy-eh=false`
  and links the EH-enabled archives `libc++abi-eh.a` + `libunwind-eh.a` (staged into the sysroot by
  `compilers/clang/build.sh`) instead of the no-EH `-lc++abi`. try/throw/catch + RAII unwinding work. This lane is
  SINGLE-THREADED (wasm32-wasip1/no-threads); the wasm32-wasi-threads lane would need its own EH archive.
  opts: `:std` (default "c++17"), `:exceptions` (default false), plus everything `compile_c/2` accepts
  (`:argv`, `:link_libs`, `:includes`, `:aux_files`, …).
  """
  def compile_cpp(source_path, opts \\ [], root \\ Shared.default_root()) do
    std = Keyword.get(opts, :std, "c++17")
    exceptions? = Keyword.get(opts, :exceptions, false)

    {eh_argv, eh_libs} =
      if exceptions? do
        cpp_eh_args()
      else
        {["-fno-exceptions"], ["-lc++", "-lc++abi"]}
      end

    cxx_argv = ["-x", "c++", "-std=#{std}"] ++ eh_argv ++ Keyword.get(opts, :argv, [])
    cxx_libs = eh_libs ++ Keyword.get(opts, :link_libs, [])

    compile_c(source_path, Keyword.merge(opts, argv: cxx_argv, link_libs: cxx_libs), root)
  end

  # ── threads lane ───────────────────────────────────────────────────────────
  @threads_libdir "/usr/lib/wasm32-wasi-threads"

  @doc """
  Compile + LINK C source to a SHARED-MEMORY MULTITHREADED wasm (wasm32-wasi-threads) — real pthreads/atomics.
  Targets the threads sysroot (shared-memory libc + pthread crt), builds with `-pthread`, and links with
  `--shared-memory --import-memory --export-memory --max-memory` + `-lpthread`. The produced wasm imports
  `wasi:thread-spawn` and a SHARED memory; run it via `PackageManager.run(wasm, …, threads: true)` (which sets
  `-W threads -W shared-memory -S threads` and drops fuel/timeout — they trap child threads). opts: `:max_memory`
  (bytes, default 1 GiB) + everything `compile_c/2` accepts. (Needs the wasm32-wasi-threads sysroot staged.)
  """
  def compile_threads(source_path, opts \\ [], root \\ Shared.default_root()) do
    max_mem = Keyword.get(opts, :max_memory, 1024 * 1024 * 1024)

    th_argv = ["-pthread"] ++ Keyword.get(opts, :argv, [])

    th_ld =
      ["--shared-memory", "--import-memory", "--export-memory", "--max-memory=#{max_mem}"] ++
        Keyword.get(opts, :ld_args, [])

    th_libs = ["-lpthread"] ++ Keyword.get(opts, :link_libs, [])

    compile_c(
      source_path,
      Keyword.merge(opts,
        target: "wasm32-wasi-threads",
        libc_dir: @threads_libdir,
        argv: th_argv,
        ld_args: th_ld,
        link_libs: th_libs
      ),
      root
    )
  end

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
  def compile_c(source_path, opts \\ [], root \\ Shared.default_root()) do
    m = Path.join([root, "clang", "manifest.html"])
    cli = kw(m, "CLI_BIN") || "clang"
    sysroot = Path.expand(Path.join([root, "clang", kw(m, "SYSROOT") || "clang-root/sysroot"]))
    target = Keyword.get(opts, :target, kw(m, "TARGET") || "wasm32-wasip1")
    extra = Keyword.get(opts, :argv, [])
    includes = Keyword.get(opts, :includes, [])
    # the libc/crt dir inside the sysroot — overridable so the threads lane (compile_threads) can point at
    # wasm32-wasi-threads (shared-memory libc + pthread crt) instead of the default wasm32-wasip1.
    libc_dir = Keyword.get(opts, :libc_dir, @clang_lib_c)

    cond do
      not File.dir?(Path.join(sysroot, "lib")) ->
        {:error, {:not_built, sysroot}}

      true ->
        # ensure the clang multitool command is registered (idempotent)
        if CommandRegistry.run(cli, "", ["--version"]) == {:error, {:unknown_command, cli}},
          do: Workbooks.Compilers.build("clang", root)

        id = Integer.to_string(:erlang.unique_integer([:positive]))
        job = Path.join(System.tmp_dir!(), "clangjob-#{id}")
        File.mkdir_p!(Path.join(job, "tmp"))
        # Source staging — three modes (wb-4b61 unity + wb-jsc4 structure):
        #   :src_root set + file under it → STRUCTURED: keep its path relative to the root, so a .c
        #     #include'ing another .c by name (lz4hc.c→lz4.c) AND a relative-parent #include
        #     "../foo.h" (zstd) both resolve. Subsumes :preserve_names. (The C-dir harvest sets this.)
        #   :src_root or :preserve_names, file NOT under root (shims, injected mains) → basename at root.
        #   neither → legacy fixed src.c / extra<i>.c (the mrustc/zig callers, untouched).
        src_root = Keyword.get(opts, :src_root)
        preserve = Keyword.get(opts, :preserve_names, false)
        root_abs = src_root && Path.expand(src_root)

        stage = fn host, fallback ->
          abs_host = Path.expand(host)

          rel =
            cond do
              root_abs && String.starts_with?(abs_host, root_abs <> "/") -> Path.relative_to(abs_host, root_abs)
              src_root || preserve -> Path.basename(host)
              true -> fallback
            end

          dst = Path.join(job, rel)
          File.mkdir_p!(Path.dirname(dst))
          File.cp!(abs_host, dst)
          rel
        end

        ext = Path.extname(source_path)
        srcname = stage.(source_path, "src" <> if(ext == "", do: ".c", else: ext))

        # extra C sources compiled + linked alongside the main one (e.g. the zig wasi shim)
        extra_csrc = Keyword.get(opts, :extra_csrc, [])
        extra_names = extra_csrc |> Enum.with_index() |> Enum.map(fn {host, i} -> stage.(host, "extra#{i}.c") end)

        # Companion files copied into /work but NOT compiled — project headers (so a relative
        # `#include "util.h"` resolves against the source dir) and any data the build reads.
        # Each is {host_path, guest_rel}; structure under /work is preserved (wb-yi7q).
        for {host, rel} <- Keyword.get(opts, :aux_files, []) do
          dst = Path.join(job, rel)
          File.mkdir_p!(Path.dirname(dst))
          File.cp!(Path.expand(host), dst)
        end

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

        # Compile the sources in PARALLEL — each clang invocation reads a DISTINCT source (read-only)
        # and writes a DISTINCT object in the shared /work (outputs never collide), so concurrent
        # wasmtime processes are safe. ~1.7x on a 33-file build (Lua 280s→166s; clang.wasm is CPU-bound
        # so N instances compete rather than scale linearly). Capped so heavy instances don't OOM.
        conc =
          case System.get_env("WB_CC_CONC") do
            nil -> max(1, min(System.schedulers_online() - 1, 6))
            v -> max(1, String.to_integer(v))
          end

        logs1 =
          srcs
          |> Task.async_stream(
            fn {sn, on} ->
              CommandRegistry.run(
                cli,
                "",
                ["clang", "--target=#{target}", "--sysroot=/usr", "-O2"] ++
                  inc_flags ++ extra ++ ["-c", "/work/#{sn}", "-o", "/work/#{on}"],
                preopens,
                ropts
              )
            end,
            max_concurrency: conc,
            timeout: :infinity,
            ordered: true
          )
          |> Enum.map(fn {:ok, log} -> log end)

        log1 = List.first(logs1)
        objs = Enum.map(srcs, fn {_, on} -> on end)
        all_objs? = Enum.all?(objs, &File.regular?(Path.join(job, &1)))

        result =
          if all_objs? do
            # crt1 provides _start for plain C; a zig C-backend object brings its own _start
            # (and libc init), so the zig chain links with crt: false to avoid a dup _start.
            crt = if Keyword.get(opts, :crt, true), do: ["#{libc_dir}/crt1-command.o"], else: []
            obj_paths = Enum.map(objs, &"/work/#{&1}")

            # opts[:ld_args] are extra wasm-ld flags (e.g. --wrap=mmap for the mmap
            # shim). They must precede the objects/libs so symbol wrapping applies.
            ld_extra = Keyword.get(opts, :ld_args, [])

            # opts[:link_libs] are -l libs that must come AFTER the objects (an archive only
            # pulls members satisfying PRECEDING undefined symbols), e.g. -lsetjmp providing
            # __wasm_setjmp/__wasm_longjmp for -wasm-enable-sjlj output (wb-nwd7).
            link_libs = Keyword.get(opts, :link_libs, [])

            # Stack: wasm-ld defaults to a 64 KiB stack, which overflows on modest
            # automatic buffers (a `char[65536]` blows it → __stack_pointer goes
            # out of bounds → faults even unrelated frames) and starves buffered
            # FILE* stdio's lazy buffer. 8 MiB matches native expectations so any
            # C command compiles to a robust binary. (wb-9ja)
            c2 =
              ["wasm-ld", "-m", "wasm32", "-z", "stack-size=8388608", "-L#{@clang_lib_rt}", "-L#{libc_dir}"] ++
                ld_extra ++ crt ++ obj_paths ++ link_libs ++
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
            # Report the sources whose object is MISSING (the real failure), not just the first
            # source's log — multi-file builds were hiding which file actually broke (wb-nsdc).
            failing =
              Enum.zip(srcs, logs1)
              |> Enum.reject(fn {{_sn, on}, _log} -> File.regular?(Path.join(job, on)) end)
              |> Enum.map(fn {{sn, _on}, log} ->
                txt = case log do
                  {:ok, t} -> t
                  other -> inspect(other)
                end

                "[#{sn}] " <> String.slice(to_string(txt), 0, 600)
              end)

            {:error, {:compile_failed, Enum.join(failing, "\n--- next failing source ---\n")}}
          end

        File.rm_rf(job)
        result
    end
  end

  @doc """
  Source → KERNEL recipe (wb-pkh.1): compile C to a `bytes → bytes` reactor module
  for the hot kernel path (Workbooks.Kernel), NOT a stdio CLI. Links with
  `crt: false` + `--no-entry` (no `_start`) so the result is a reactor; the kernel
  exports its entry + arena pointers.

  KERNEL C ABI — the author writes (export_name does the exports; the recipe drops
  `_start` and keeps `memory`):

      static unsigned char IN[N], OUT[N];
      __attribute__((export_name("in_ptr")))  int in_ptr(void)  { return (int)(long)IN; }
      __attribute__((export_name("out_ptr"))) int out_ptr(void) { return (int)(long)OUT; }
      __attribute__((export_name("process"))) int process(int in_len) { …; return out_len; }

  Open it with `Workbooks.Kernel.open(bytes, arena: :exports)` — the host queries
  in_ptr/out_ptr (the linker, not the author, placed the buffers) then loops
  `process` per frame. Returns {:ok, wasm_path, logs} | {:error, _}.
  """
  def c_compile_to_kernel(source_path, root \\ Shared.default_root()) do
    compile_c(source_path, [crt: false, ld_args: ["--no-entry", "--export-memory"]], root)
  end

  @doc """
  Compile C → wasm with clang in-sandbox, then RUN the emitted wasm in-sandbox. The whole
  pipeline (compile, link, execute) is zero native execution. Returns {:ok, output}.
  """
  def compile_and_run_c(source_path, run_argv \\ [], opts \\ [], root \\ Shared.default_root()) do
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
  def zig_compile_to_wasm(source_path, opts \\ [], root \\ Shared.default_root()) do
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
        zm = Path.join([root, "zig", "manifest.html"])
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
  def zig_compile_and_run(source_path, run_argv \\ [], opts \\ [], root \\ Shared.default_root()) do
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
end
