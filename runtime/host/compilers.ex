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

  # clang/lld (YoWASP LLVM-for-wasi) link paths inside the mounted sysroot (/usr).
  @clang_lib_rt "/usr/lib/wasm32-unknown-wasip1"
  @clang_lib_c "/usr/lib/wasm32-wasip1"

  # wb-346: curated reduced-feature sets tried first in the :reduce fallback for crates whose full
  # default exceeds the mrustc ceiling but a middle set keeps key capability. List-of-feature-sets.
  @feature_hints %{
    "regex" => [["std", "unicode-perl"]],
    "regex-syntax" => [["std", "unicode-perl"]]
  }

  # wb-ctk: known-good version FLOORS for crates whose newest releases exceed the mrustc ~1.74
  # ceiling (newer regex pulls regex-automata; syn/serde_derive went to syn-2 / edition-2024). The
  # resolver tries the floor FIRST when it satisfies the caller's req, so a bare `regex` resolves to
  # a buildable version instead of walking 6 doomed newest ones. An explicit pin still wins.
  # wb-5bv: mrustc can't resolve a RE-EXPORTED proc-macro derive (`use serde::Serialize` →
  # serde's `pub use serde_derive::*`). Rather than fork the compiler, the BEAM normalizes the
  # SOURCE: when a proc-macro crate that re-exports derives is in the tree and the user invokes one
  # of those derives, inject `use <derive_crate>::<Derive>` — which coexists with the user's
  # `use serde::Serialize` (trait = type namespace, derive = macro namespace; verified). Keyed by
  # the derive crate (crate_id form) → the derive names it provides.
  @derive_reexports %{
    "serde_derive" => ~w(Serialize Deserialize)
  }

  @version_floors %{
    "regex" => "1.5.4",
    "regex-syntax" => "0.6.29",
    "syn" => "1.0.109",
    "serde" => "1.0.156",
    "serde_derive" => "1.0.156",
    "proc-macro2" => "1.0.69",
    "quote" => "1.0.33",
    "unicode-ident" => "1.0.12"
  }

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
  # EH archives live in the libc/crt dir of the wasm32-wasip1 sysroot (guest path), staged by build.sh.
  @cpp_eh_abi "#{@clang_lib_c}/libc++abi-eh.a"
  @cpp_eh_unwind "#{@clang_lib_c}/libunwind-eh.a"

  @doc """
  Whether the from-source C++ EH runtime (`libc++abi-eh.a`) is staged in the wasm32-wasip1 sysroot. When
  true, C++ can link the standardized wasm-exceptions runtime; when false, only the no-exceptions subset
  links. (`@clang_lib_c` is the GUEST path /usr/lib/…; this checks the HOST sysroot under `root`.)
  """
  def cpp_eh_staged?(root \\ default_root()) do
    File.regular?(Path.join([root, "clang", "clang-root", "sysroot", "lib", "wasm32-wasip1", "libc++abi-eh.a"]))
  end

  @doc """
  C++ EH link config `{compile_flags, link_libs}` for the NEW standardized wasm EH (`try_table`/`exnref` —
  the only kind wasmtime 45 `-W exceptions=y` runs), linking the from-source EH `libc++abi-eh.a` +
  `libunwind-eh.a` instead of the no-EH `-lc++abi`. ONE home, shared by `compile_cpp` and
  `PackageManager.build_c_dir`, so the exceptions wiring never drifts between the single-file and dir lanes.
  """
  def cpp_eh_args, do: {["-fwasm-exceptions", "-mllvm", "-wasm-use-legacy-eh=false"], ["-lc++", @cpp_eh_abi, @cpp_eh_unwind]}

  def compile_cpp(source_path, opts \\ [], root \\ default_root()) do
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

  @threads_libdir "/usr/lib/wasm32-wasi-threads"

  @doc """
  Compile + LINK C source to a SHARED-MEMORY MULTITHREADED wasm (wasm32-wasi-threads) — real pthreads/atomics.
  Targets the threads sysroot (shared-memory libc + pthread crt), builds with `-pthread`, and links with
  `--shared-memory --import-memory --export-memory --max-memory` + `-lpthread`. The produced wasm imports
  `wasi:thread-spawn` and a SHARED memory; run it via `PackageManager.run(wasm, …, threads: true)` (which sets
  `-W threads -W shared-memory -S threads` and drops fuel/timeout — they trap child threads). opts: `:max_memory`
  (bytes, default 1 GiB) + everything `compile_c/2` accepts. (Needs the wasm32-wasi-threads sysroot staged.)
  """
  def compile_threads(source_path, opts \\ [], root \\ default_root()) do
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

  def compile_c(source_path, opts \\ [], root \\ default_root()) do
    m = Path.join([root, "clang", "manifest.org"])
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
          do: build("clang", root)

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
  def c_compile_to_kernel(source_path, root \\ default_root()) do
    compile_c(source_path, [crt: false, ld_args: ["--no-entry", "--export-memory"]], root)
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

  # SHARED-MEMORY THREADS variant of @rust_clang_flags (compile_rust_threads): wasm32-wasi-threads
  # target + -pthread -matomics -mbulk-memory so the std .o and user .o carry atomics codegen and link
  # against the threads sysroot's shared-memory libc (must match the threads libstd's own .o).
  @rust_threads_clang_flags ~w(--target=wasm32-wasi-threads --sysroot=/usr -pthread -matomics
                       -mbulk-memory -O1 -fno-strict-aliasing -w
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
    case rust_compile_to_wasm_impl(source_path, opts, root) do
      {:error, _} = err ->
        # wb-0sz: classify the failure into an actionable hint so the caller (agent or person) learns
        # WHICH limitation they hit and WHAT to do — not just a wasm trap. Diagnosis is also returnable
        # via Workbooks.Compilers.RustCaps.diagnose/1; here we surface it in the log.
        d = Workbooks.Compilers.RustCaps.diagnose(err)
        require Logger
        Logger.warning("[rust] compile failed [#{d.category}]: #{d.summary} — mitigation: #{d.mitigation}")
        err

      ok ->
        ok
    end
  end

  defp rust_compile_to_wasm_impl(source_path, opts, root) do
    rd = Path.join(root, "rust")
    mrdir = Path.expand(Path.join(rd, "mrustc-root/mrustc"))
    mrwasm = Path.expand(Path.join(rd, "mrustc-root/mrustc_std.wasm"))
    clang = Path.expand(Path.join([root, "clang", "clang-root", "llvm.core.wasm"]))
    csys = Path.expand(Path.join([root, "clang", "clang-root", "sysroot"]))
    shim_src = Path.expand(Path.join([root, "zig", "wasi_shim.c"]))
    ustub_src = Path.expand(Path.join([rd, "std", "ustub.c"]))
    stub_src = Path.expand(Path.join([rd, "std", "setjmp-stub.h"]))
    o = Path.join(mrdir, "output-wasi-174")

    cond do
      not File.regular?(mrwasm) -> {:error, {:mrustc_not_built, mrwasm}}
      not File.regular?(clang) -> {:error, {:clang_not_built, clang}}
      not File.regular?(Path.join(o, "libstd.rlib.o")) -> {:error, {:libstd_not_prebuilt, o}}
      true -> do_rust_compile(source_path, mrdir, mrwasm, clang, csys, o, shim_src, ustub_src, stub_src, opts)
    end
  end

  defp do_rust_compile(source_path, mrdir, mrwasm, clang, csys, o, shim_src, ustub_src, stub_src, opts) do
    id = Integer.to_string(:erlang.unique_integer([:positive]))
    name = "wbr#{id}"
    File.mkdir_p!(Path.join(mrdir, ".mrtmp"))
    File.mkdir_p!(Path.join(mrdir, ".cctmp"))
    File.cp!(Path.expand(source_path), Path.join(o, "#{name}.rs"))

    # wb-49z: no_exceptions lane — emit a wasm WITHOUT the exceptions proposal (sjlj) so it runs
    # under Wasmex (BEAM) for host-mediated caps (the Dock). Swap clang exception flags for a stub
    # setjmp.h (-I before sysroot): mrustc's C #includes <setjmp.h> which #errors w/o sjlj; the stub
    # no-ops setjmp + traps longjmp (safe — no unwind, panic→abort). Assumes no-dep (or all deps
    # also no-exc); deps still compile with default exception flags, so use only for minimal Dock
    # programs until dep-lane threading lands.
    noexc? = Keyword.get(opts, :no_exceptions, false)
    clang_flags =
      if noexc? do
        File.mkdir_p!(Path.join(mrdir, "stubinc"))
        File.cp!(stub_src, Path.join([mrdir, "stubinc", "setjmp.h"]))
        ~w(--target=wasm32-wasip1 --sysroot=/usr -I/work/stubinc -O1 -fno-strict-aliasing -w
           -Xclang -disable-llvm-verifier)
      else
        @rust_clang_flags
      end

    # wasm SIMD (proven via the CFG sweep): -msimd128 enables the v128 target feature and -O2 turns on clang
    # AUTOVECTORIZATION (off at -O1 even with -msimd128) — the only path to real v128 ops, since mrustc lowers
    # Rust SIMD intrinsics to scalar C. Applies to the user-code compile. Orthogonal to the threads lane (SIMD
    # is a C-compile flag; atomics is an mrustc cfg), so they compose. -O2 overrides the earlier -O1 (last wins).
    clang_flags =
      if Keyword.get(opts, :simd, false), do: clang_flags ++ ["-msimd128", "-O2"], else: clang_flags

    mr = fn args ->
      wasmtime(
        ["-W", "exceptions=y", "-W", "max-wasm-stack=134217728",
         "--env", "MRUSTC_TARGET_VER=1.74", "--env", "STD_ENV_ARCH=wasm32", "--env", "TMPDIR=/tmp",
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

    # wb-mrz: start each top-level build with an EMPTY deps/ dir. The obj-level cache in
    # compile_dep returns [] for a cached dep's transitive sub-dep objects; a warm or
    # cross-program deps/ would therefore drop sub-dep .o files from the final link
    # (undefined symbols → "flaky" link failures, e.g. regex's aho-corasick/memchr objs).
    # Building fresh per program + globbing deps/ at link time (below) makes the link list
    # complete and deterministic regardless of which deps hit the cache mid-tree.
    File.rm_rf(Path.join(o, "deps"))

    # wb-3s8/wb-6lh: fetch + compile each declared crates.io dependency (pure-Rust, in-sandbox)
    # into output-wasi-174/deps/, returning {extern_args, dep_object_paths}. Errors short-circuit.
    case ensure_deps(Keyword.get(opts, :deps, []), mrdir, o, mr, cl, Keyword.get(opts, :dep_features, %{})) do
      {:error, _} = depserr ->
        for ext <- ~w(rs c o hir wasm), do: File.rm(Path.join(o, "#{name}.#{ext}"))
        depserr

      {:ok, extern_args0, _dep_objs0} ->
        all_dep_objs = Path.wildcard(Path.join(o, "deps/*.rlib.o"))

        # wb-v3d: proc-macro routing. ensure_deps dropped `.pmonly`/`.pmentry` markers. `.pmonly`
        # objects are proc-macro build-time-only (kept OUT of the runtime link, linked INTO a server
        # wasm instead); each `.pmentry` is a proc-macro crate the user externs → build its server +
        # rewrite its --extern. When any exist, the user compile runs under Wasmex (mrustc_pm.wasm)
        # so derives EXECUTE; with none, the plain CLI path below is byte-for-byte unchanged.
        pmonly =
          Path.wildcard(Path.join(o, "deps/*.rlib.o.pmonly"))
          |> Enum.map(&"/work/output-wasi-174/deps/#{Path.basename(String.replace_suffix(&1, ".pmonly", ""))}")
          |> MapSet.new()

        {pm_servers, pm_externs} = build_pm_servers(o, cl, extern_args0)

        # wb-asw: auto-provide the `wb` BEAM-runtime crate so programs can `use wb;` (opt-in).
        {wb_extern, wb_obj} =
          if Keyword.get(opts, :wb, false), do: wb_runtime(o, mr, cl, clang_flags), else: {[], []}

        extern_args = extern_args0 ++ pm_externs ++ wb_extern

        # wb-5bv: normalize re-exported derives in the user source (the BEAM-side fix for the serde
        # idiom — no compiler change). Conservative: only for derive crates actually built, only
        # derives actually used, only when not already imported directly.
        if pm_servers != [], do: inject_reexport_imports(Path.join(o, "#{name}.rs"), o)

        # wb-mrz: link EVERY compiled dep object present in deps/ (sorted → deterministic) EXCEPT the
        # proc-macro subtree. deps/ was cleaned at build start, so it holds exactly this tree.
        dep_objs =
          (all_dep_objs
           |> Enum.sort()
           |> Enum.map(&"/work/output-wasi-174/deps/#{Path.basename(&1)}")
           |> Enum.reject(&MapSet.member?(pmonly, &1))) ++ wb_obj

        ldirs = if all_dep_objs == [], do: [], else: ["-L", "output-wasi-174/deps"]

        user_args =
          ["output-wasi-174/#{name}.rs", "--crate-name", name, "--crate-type", "bin",
           "-L", "output-wasi-174"] ++ ldirs ++ extern_args ++
            ["--out-dir", "output-wasi-174", "--target", "wasm32-wasi", "--edition", "2021"]

        log1 =
          if pm_servers == [] do
            mr.(user_args)
          else
            pm_wasm = Path.join(Path.dirname(mrdir), "mrustc_pm.wasm")
            env = %{"MRUSTC_TARGET_VER" => "1.74", "STD_ENV_ARCH" => "wasm32", "TMPDIR" => "/tmp"}

            case Workbooks.ProcMacroHost.run_mrustc(pm_wasm, user_args, mrdir, env) do
              {:ok, out} -> out
              {:error, e} -> inspect(e)
            end
          end

        result =
          if File.regular?(Path.join(o, "#{name}.c")) do
            cl.(["clang"] ++ clang_flags ++ ["-c", "/work/output-wasi-174/#{name}.c", "-o", "/work/output-wasi-174/#{name}.o"])

            if File.regular?(Path.join(o, "#{name}.o")) do
              libstd = Path.wildcard(Path.join(o, "*.rlib.o")) |> Enum.map(&"/work/output-wasi-174/#{Path.basename(&1)}")

              # --allow-undefined: leave unresolved externs as wasm IMPORTS instead of erroring
              # — the path for BEAM-mediated host functions (the Dock) called from compiled Rust
              # (wb-1mv). Off by default (a real link error should still fail loudly).
              au = if Keyword.get(opts, :allow_undefined, false), do: ["--allow-undefined"], else: []

              ld =
                ["wasm-ld", "-m", "wasm32", "-L/usr/lib/wasm32-unknown-wasip1", "-L/usr/lib/wasm32-wasip1"] ++
                  au ++
                  ["/usr/lib/wasm32-wasip1/crt1-command.o", "/work/output-wasi-174/#{name}.o"] ++
                  dep_objs ++ libstd ++
                  ["/work/output-wasi-174/wasi_shim.o", "/work/output-wasi-174/ustub.o",
                   "-lc", "-lsetjmp", "/usr/lib/wasm32-unknown-wasip1/libclang_rt.builtins.a",
                   "-o", "/work/output-wasi-174/#{name}.wasm"]

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

  # ── Rust SHARED-MEMORY THREADS lane (multithreaded Rust → wasm32-wasi-threads) ──────────────
  @threads_o "output-wasi-174-threads"

  @doc """
  Compile untrusted MULTITHREADED Rust (real `std::thread` + atomics) → a shared-memory wasm
  entirely in the sandbox. Mirrors `rust_compile_to_wasm/3` but onto the THREADS toolchain:

    * transpile with mrustc.wasm + `--cfg target_feature=atomics` (the no-fork bypass: mrustc's
      cfg.cpp checks CLI --cfg FIRST, so cfg(target_feature="atomics") → true and the hardcoded
      `target.cpp:746 return false` is never reached — target.cpp untouched, base lane unaffected);
    * compile the emitted C with `@rust_threads_clang_flags` (wasm32-wasi-threads + atomics);
    * link mirroring `compile_threads/3` (the C threads lane): shared imported/exported memory,
      `-lpthread`, the threads sysroot crt + libc, routing the `wasi:thread-spawn` import;
    * link against the THREADS libstd (`output-wasi-174-threads/`) — its `.rlib.hir` (used by mrustc
      above) and its `.o` come from the same atomics override build, so monomorph hashes agree (a
      base-vs-threads HIR mismatch yields undefined `spawn_unchecked` hash symbols at link).

  Run the result via `PackageManager.run(wasm, …, threads: true)` (shared-memory + thread-spawn).
  Requires the threads libstd prebuild (compilers/rust/std/prebuild-libstd-threads-174.sh). Absent →
  `{:error, {:libstd_threads_not_prebuilt, dir}}`. Single-crate (no crates.io deps) — the proven
  parallel-compute shape. Returns `{:ok, wasm_path, log} | {:error, reason}`.

  opts: `:max_memory` (bytes, default 1 GiB).
  """
  def compile_rust_threads(source_path, opts \\ [], root \\ default_root()) do
    rd = Path.join(root, "rust")
    mrdir = Path.expand(Path.join(rd, "mrustc-root/mrustc"))
    mrwasm = Path.expand(Path.join(rd, "mrustc-root/mrustc_std.wasm"))
    clang = Path.expand(Path.join([root, "clang", "clang-root", "llvm.core.wasm"]))
    csys = Path.expand(Path.join([root, "clang", "clang-root", "sysroot"]))
    o = Path.join(mrdir, @threads_o)

    cond do
      not File.regular?(mrwasm) -> {:error, {:mrustc_not_built, mrwasm}}
      not File.regular?(clang) -> {:error, {:clang_not_built, clang}}
      not File.regular?(Path.join(o, "libstd.rlib.o")) -> {:error, {:libstd_threads_not_prebuilt, o}}
      true -> do_rust_threads_compile(source_path, mrdir, mrwasm, clang, csys, o, opts)
    end
  end

  defp do_rust_threads_compile(source_path, mrdir, mrwasm, clang, csys, o, opts) do
    id = Integer.to_string(:erlang.unique_integer([:positive]))
    name = "wbrt#{id}"
    max_mem = Keyword.get(opts, :max_memory, 1024 * 1024 * 1024)
    rd = Path.dirname(Path.dirname(mrdir))
    shim_src = Path.expand(Path.join([Path.dirname(rd), "zig", "wasi_shim.c"]))
    ustub_src = Path.expand(Path.join([rd, "std", "ustub.c"]))
    File.mkdir_p!(Path.join(mrdir, ".mrtmp"))
    File.mkdir_p!(Path.join(mrdir, ".cctmp"))
    File.cp!(Path.expand(source_path), Path.join(o, "#{name}.rs"))

    mr = fn args ->
      wasmtime(
        ["-W", "exceptions=y", "-W", "max-wasm-stack=134217728",
         "--env", "MRUSTC_TARGET_VER=1.74", "--env", "STD_ENV_ARCH=wasm32", "--env", "TMPDIR=/tmp",
         "--dir", "#{mrdir}::.", "--dir", "#{mrdir}/.mrtmp::/tmp", mrwasm | args]
      )
    end

    cl = fn args ->
      wasmtime(
        ["-W", "exceptions=y", "--dir", "#{csys}::/usr", "--dir", "#{mrdir}::/work",
         "--dir", "#{mrdir}/.cctmp::/tmp", "--env", "TMPDIR=/tmp", clang | args]
      )
    end

    # wb-rayon: crates.io deps on the THREADS lane (rayon-core et al). Same dep machinery as the base
    # lane, driven by threads_deps_ctx → output-wasi-174-threads/deps + @rust_threads_clang_flags +
    # `--cfg target_feature=atomics`. Pure-Rust/build.rs only (rayon-core's tree: either + crossbeam-*
    # — no proc-macros), so no pm-server routing here. Fresh deps/ per build (mirrors base lane wb-mrz).
    File.rm_rf(Path.join(o, "deps"))

    case ensure_deps(
           Keyword.get(opts, :deps, []),
           mrdir,
           o,
           mr,
           cl,
           Keyword.get(opts, :dep_features, %{}),
           threads_deps_ctx()
         ) do
      {:error, _} = depserr ->
        for ext <- ~w(rs c o hir wasm), do: File.rm(Path.join(o, "#{name}.#{ext}"))
        depserr

      {:ok, extern_args, _dep_objs} ->
        all_dep_objs = Path.wildcard(Path.join(o, "deps/*.rlib.o"))

        dep_obj_args =
          all_dep_objs |> Enum.sort() |> Enum.map(&"/work/#{@threads_o}/deps/#{Path.basename(&1)}")

        ldirs = if all_dep_objs == [], do: [], else: ["-L", "#{@threads_o}/deps"]

        # transpile .rs → C against the THREADS libstd, with the atomics-cfg bypass so mrustc emits
        # shared-memory-aware code paths (and selects the threads std cfg the HIR was built with).
        user_args =
          ["#{@threads_o}/#{name}.rs", "--crate-name", name, "--crate-type", "bin", "-L", @threads_o] ++
            ldirs ++
            extern_args ++
            ["--out-dir", @threads_o, "--target", "wasm32-wasi", "--edition", "2021", "--cfg", "target_feature=atomics"]

        log1 = mr.(user_args)

        # shared shim + unwind-stub objects, built for the THREADS target (wasm32-wasi-threads) so they
        # link against the same shared-memory libc. ustub.o supplies the _Unwind_Resume stub (panic=abort).
        ensure_rust_threads_obj(o, "wasi_shim", shim_src, cl)
        ensure_rust_threads_obj(o, "ustub", ustub_src, cl)

        result =
          if File.regular?(Path.join(o, "#{name}.c")) do
            cl.(["clang"] ++ @rust_threads_clang_flags ++ ["-c", "/work/#{@threads_o}/#{name}.c", "-o", "/work/#{@threads_o}/#{name}.o"])

            if File.regular?(Path.join(o, "#{name}.o")) do
              libstd = Path.wildcard(Path.join(o, "*.rlib.o")) |> Enum.map(&"/work/#{@threads_o}/#{Path.basename(&1)}")

              # Link mirrors the C threads lane (compile_threads): shared imported/exported memory +
              # -lpthread against the wasm32-wasi-threads sysroot. crt1.o (the threads crt provides the
              # thread-spawn-aware _start + TLS init), threads libc, builtins from wasm32-unknown-wasip1.
              # dep_obj_args carries the compiled crates.io dependency objects (rayon-core et al).
              ld =
                ["wasm-ld", "-m", "wasm32", "--shared-memory", "--import-memory", "--export-memory", "--max-memory=#{max_mem}", "-L/usr/lib/wasm32-unknown-wasip1", "-L/usr/lib/wasm32-wasi-threads", "/usr/lib/wasm32-wasi-threads/crt1.o", "/work/#{@threads_o}/#{name}.o"] ++
                  dep_obj_args ++
                  libstd ++
                  ["/work/#{@threads_o}/wasi_shim.o", "/work/#{@threads_o}/ustub.o", "-lc", "-lpthread", "-lsetjmp", "/usr/lib/wasm32-unknown-wasip1/libclang_rt.builtins.a", "-o", "/work/#{@threads_o}/#{name}.wasm"]

              log2 = cl.(ld)
              outw = Path.join(o, "#{name}.wasm")

              if File.regular?(outw) do
                dest = Path.join(System.tmp_dir!(), "wbrust-threads-#{id}.wasm")
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

        for ext <- ~w(rs c o hir wasm), do: File.rm(Path.join(o, "#{name}.#{ext}"))
        File.rm(Path.join(o, "lib#{name}.rlib"))
        result
    end
  end

  # ── crates.io dependency support (wb-3s8 / wb-6lh) ──────────────────────────
  # Each dep: %{name, version} | {name, version} | "name@version". Fetched from the static
  # CDN, compiled (with its default features) via mrustc.wasm→clang.wasm into output-wasi-174/deps/,
  # cached by name+version. Returns {:ok, extern_args, dep_object_guest_paths} | {:error, _}.
  # Pure-Rust only (no proc-macros / build.rs / transitive deps yet — the next slices).
  # wb-rayon: deps-lane CONTEXT — lets the SAME dep machinery target either the base lane
  # (output-wasi-174 + @rust_clang_flags) or the THREADS lane (output-wasi-174-threads +
  # @rust_threads_clang_flags + `--cfg target_feature=atomics`), instead of forking the recursion.
  #   :o_rel       — the lane's output dir relative to mrdir (the guest /work root)
  #   :clang_flags — the clang .c→.o flags for this lane
  #   :cfgs        — extra mrustc `--cfg` args every crate in the lane is transpiled with
  defp base_deps_ctx, do: %{o_rel: "output-wasi-174", clang_flags: @rust_clang_flags, cfgs: []}

  defp threads_deps_ctx,
    do: %{o_rel: @threads_o, clang_flags: @rust_threads_clang_flags, cfgs: ["--cfg", "target_feature=atomics"]}

  defp ensure_deps(deps, mrdir, o, mr, cl, feats, ctx \\ nil)
  defp ensure_deps([], _mrdir, _o, _mr, _cl, _feats, _ctx), do: {:ok, [], []}

  defp ensure_deps(deps, mrdir, o, mr, cl, feats, ctx0) do
    ctx = ctx0 || base_deps_ctx()
    File.mkdir_p!(Path.join(o, "deps"))

    Enum.reduce_while(deps, {:ok, [], []}, fn dep, {:ok, externs, objs} ->
      {name, version} = parse_dep(dep)

      case compile_dep(name, version, mrdir, o, mr, cl, feats, true, false, ctx) do
        {:ok, rlib_rel, obj_guest, dep_objs} ->
          {:cont, {:ok, externs ++ ["--extern", "#{crate_id(name)}=#{rlib_rel}"], objs ++ [obj_guest | dep_objs]}}

        {:error, _} = e ->
          {:halt, e}
      end
    end)
  end

  # wb-v3d: for each `.pmentry` marker, link a proc-macro SERVER wasm from the proc-macro subtree
  # (every `.pmonly` object + libstd, which carries the proc_macro server runtime). Returns the list
  # of linked server paths. NO --extern rewrite or `.hir` copy: mrustc loads each proc-macro crate's
  # HIR from its own `lib<crate>.rlib.hir` (it does for transitive proc-macros like serde_derive too),
  # and Workbooks.ProcMacroHost maps the loaded `lib<crate>.rlib` path → `<crate>_server.wasm` at run
  # time — so this handles BOTH top-level and transitive proc-macro crates uniformly.
  defp build_pm_servers(o, cl, extern_args) do
    case Path.wildcard(Path.join(o, "deps/*.rlib.o.pmentry")) do
      [] ->
        {[], []}

      entries ->
        pmonly_objs =
          Path.wildcard(Path.join(o, "deps/*.rlib.o.pmonly"))
          |> Enum.map(&"/work/output-wasi-174/deps/#{Path.basename(String.replace_suffix(&1, ".pmonly", ""))}")

        libstd = Path.wildcard(Path.join(o, "*.rlib.o")) |> Enum.map(&"/work/output-wasi-174/#{Path.basename(&1)}")
        already = extern_args |> Enum.filter(&String.contains?(&1, "=")) |> Enum.map(&(String.split(&1, "=") |> hd())) |> MapSet.new()

        {servers, externs} =
          Enum.reduce(entries, {[], []}, fn marker, {servers, externs} ->
            [crate, rlib_rel] = String.split(File.read!(marker), "\t", parts: 2)
            server_rel = "output-wasi-174/deps/#{crate}_server.wasm"

            cl.(["wasm-ld", "-m", "wasm32", "-L/usr/lib/wasm32-unknown-wasip1", "-L/usr/lib/wasm32-wasip1",
                 "/usr/lib/wasm32-wasip1/crt1-command.o"] ++ pmonly_objs ++ libstd ++
                ["/work/output-wasi-174/wasi_shim.o", "/work/output-wasi-174/ustub.o",
                 "-lc", "-lsetjmp", "/usr/lib/wasm32-unknown-wasip1/libclang_rt.builtins.a",
                 "-o", "/work/#{server_rel}"])

            # A TRANSITIVE proc-macro (e.g. serde_derive pulled by serde's `derive` feature) isn't in
            # the user's --extern list, so a re-exported derive (`use serde::Serialize`) can't resolve
            # to its handler. --extern every proc-macro crate (build-time only; excluded from the
            # runtime link) so its derives are always visible. Skip ones already externed (top-level).
            ext = if MapSet.member?(already, crate), do: [], else: ["--extern", "#{crate}=#{rlib_rel}"]
            {[server_rel | servers], externs ++ ext}
          end)

        {servers, externs}
    end
  end

  # The Rust crate identifier used in source/--crate-name/--extern: hyphens become underscores
  # (the package name keeps hyphens for fetch/index/paths). e.g. "num-traits" → "num_traits".
  defp crate_id(name), do: String.replace(name, "-", "_")

  defp parse_dep(%{name: n, version: v}), do: {n, v}
  defp parse_dep({n, v}), do: {to_string(n), to_string(v)}
  defp parse_dep(s) when is_binary(s), do: (case String.split(s, "@", parts: 2) do
    [n, v] -> {n, v}
    [n] -> {n, "*"}
  end)

  # Compile one dependency crate (TRANSITIVELY): resolve its version via the sparse index, fetch
  # it, compile its OWN normal deps first (recursing), then compile it with --extern for each.
  # Returns {:ok, rlib_rel, obj_guest, dep_objs} where dep_objs are the transitive objects to link.
  # Cached by the .o existing. Pure-Rust only (no proc-macros/build.rs); cycles can't occur (cargo
  # forbids them) and diamonds collapse via the cache.
  # pm_ctx?: this crate is somewhere under a proc-macro crate in the dep tree. Propagated down so
  # the WHOLE proc-macro subtree (serde_derive → syn/quote/proc-macro2/unicode-ident) compiles with
  # a target_os-spoofed spec — syn gates parse_macro_input on not(wasm32+wasi), so building it for
  # os=wasi excludes the macro. See build_dep_version (wb-vqx / wb-zq4 gap #1).
  defp compile_dep(name, req, mrdir, o, mr, cl, feats, top?, pm_ctx?, ctx) do
    rlib_rel = "#{ctx.o_rel}/deps/lib#{name}.rlib"
    obj_host = Path.join(o, "deps/lib#{name}.rlib.o")
    obj_guest = "/work/#{ctx.o_rel}/deps/lib#{name}.rlib.o"

    if File.regular?(obj_host) do
      {:ok, rlib_rel, obj_guest, []}
    else
      # VERSION-FALLBACK (wb-6lh): the index gives all matching versions newest-first. Try the
      # newest; if it fails to compile (the mrustc ~1.54 ceiling on newer crate internals), walk
      # to the next-older in-range version until one compiles. Makes transitive deps practical
      # without a newer compiler — bounded to a handful of attempts.
      with {:ok, candidates} <- resolve_via_index(name, req, Map.get(feats, name)) do
        # Feature MODES to try, in order (wb-3s8). A caller override is authoritative (one mode).
        #   :full   — the crate's FULL default features (the correct, common case)
        #   :reduce — no_std fallbacks, but ONLY for a TOP-LEVEL dep (top?). A sub-dep must keep
        #             the features its dependent expects: reducing serde (pulled by serde_json) to
        #             no-std drops the std/alloc impls serde_json needs → serde_json won't compile.
        #             So sub-deps are :full-only — version-fallback finds a buildable release at full
        #             features, exactly as before auto-fallback existed. Reduction is reserved for
        #             the crate the caller directly asked for (data-encoding/nom), which has no
        #             dependent to satisfy. This also avoids a combinatorial :reduce pass over a
        #             heavy sub-tree (serde→proc-macro2 version-walk).
        modes =
          case Map.fetch(feats, name) do
            {:ok, ov} -> [{:override, ov}]
            :error -> if top?, do: [:full, :reduce], else: [:full]
          end

        result =
          Enum.reduce_while(modes, {:error, []}, fn mode, {:error, tried} ->
            inner =
              Enum.reduce_while(candidates, {:error, tried}, fn {version, subdeps}, {:error, tr} ->
                case build_dep_version(name, version, subdeps, rlib_rel, obj_host, obj_guest, mrdir, o, mr, cl, feats, mode, pm_ctx?, ctx) do
                  {:ok, _, _, _} = ok -> {:halt, ok}
                  {:error, _} -> (clean_dep_artifacts(o, name); {:cont, {:error, [version | tr]}})
                end
              end)

            case inner do
              {:ok, _, _, _} = ok -> {:halt, ok}
              {:error, _} = e -> {:cont, e}
            end
          end)

        case result do
          {:ok, _, _, _} = ok -> ok
          {:error, tried} -> {:error, {:dep_compile_failed, name, tried |> Enum.reverse() |> Enum.uniq() |> Enum.join(",")}}
        end
      end
    end
  end

  # Build a SPECIFIC version of a dep under a feature MODE: compile sub-deps first, then it.
  # mode: {:override, feats} verbatim | :full (default features only) | :reduce (no_std variants).
  defp build_dep_version(name, version, subdeps, rlib_rel, obj_host, obj_guest, mrdir, o, mr, cl, feats, mode, pm_ctx?, ctx) do
    with {:ok, lib_rs, def_features, edition, pm?} <- fetch_crate(name, version, Path.join(o, "deps")),
         # wb-vqx: once we know THIS crate is a proc-macro (pm?), its whole sub-tree must be spoofed
         # too (syn is a sub-dep, not itself a proc-macro crate, yet it carries parse_macro_input).
         spoof? = pm_ctx? or pm?,
         {:ok, sub_externs0, sub_objs} <- build_subdeps(subdeps, mrdir, o, mr, cl, feats, spoof?, ctx) do
      rel_src = Path.relative_to(lib_rs, mrdir)
      cdst = Path.join(o, "deps/lib#{name}.rlib.c")
      # wb-zq4: proc-macro crate → wire the compiler `proc_macro` crate from the std chain.
      sub_externs =
        if pm?, do: sub_externs0 ++ ["--extern", "proc_macro=#{ctx.o_rel}/libproc_macro.rlib"], else: sub_externs0

      # wb-vqx (wb-zq4 gap #1): proc-macro subtree compiles against a target_os-spoofed spec so
      # syn's `not(all(wasm32, os in (unknown,wasi)))` guard PASSES and parse_macro_input surfaces.
      # arch stays wasm32 and codegen still targets wasm32-wasi — only target_os cfg flips to linux.
      dep_target = if spoof?, do: ensure_pm_target_spec(o), else: "wasm32-wasi"

      # wb-rxi: a proc-macro crate (serde_derive etc.) MUST be built --crate-type proc-macro; mrustc
      # asserts "Procedural macros defined in non proc-macro crate" if such a crate is built as rlib.
      dep_crate_type = if pm?, do: "proc-macro", else: "rlib"

      # Feature variants for THIS mode (the two-phase resolver in compile_dep picks the mode order):
      #   :override — caller's exact set, no fallback
      #   :full     — the crate's full default features (the common, correct case)
      #   :reduce   — no_std fallbacks tried only after :full failed across ALL versions. std→alloc
      #               swap first (heap APIs like data-encoding's encode→String are alloc-gated; a
      #               spurious "alloc" cfg is a harmless no-op), then bare no-std, then none. Skips
      #               def_features itself (already tried in :full).
      # wb-346: per-crate feature HINTS — curated sets tried FIRST. The literal (non-transitive)
      # default can both exceed the ceiling AND under-enable capability: regex-syntax default
      # ["unicode"] compiles but lacks "unicode-perl" (transitively implied in real cargo) → \d =
      # Syntax error. Hint [std,unicode-perl] gives \d/\w. Applied in :full so sub-deps (which are
      # :full-only) get it too. NOTE: keep this binding OUTSIDE the `variants =` expression — nesting
      # it makes `variants` bind to `hint` and silently discards the `case` (wb-rxi regression).
      hint = Map.get(@feature_hints, name, [])

      variants =
        case mode do
          {:override, override} ->
            [override]

          :full ->
            (hint ++ [def_features]) |> Enum.uniq()

          :reduce ->
            no_std = def_features -- ["std"]
            alloc = if "std" in def_features, do: [["alloc" | no_std]], else: []
            (hint ++ alloc ++ [no_std, []]) |> Enum.uniq() |> Enum.reject(&(&1 == def_features))
        end

      # wb-zq4: EDITION-FALLBACK — try the crate's declared edition, then 2021. Some crates declare
      # 2018 but use 2021-prelude items unqualified (e.g. proc-macro2 1.0.69 → FromIterator), which
      # mrustc rejects at 2018 but accepts at 2021. Try each (feature-variant × edition) until one
      # emits the .c. Unblocks proc-macro2/syn (→ derive macros).
      editions = Enum.uniq([edition, "2021"])

      # wb-yq0: run this crate's build.rs (if any) in-sandbox once; its allowlisted rustc-cfg flags
      # apply to every feature/edition attempt.
      build_cfgs = build_script_flags(name, lib_rs, o, mr, cl)

      compiled? =
        Enum.reduce_while(variants, false, fn features, _ ->
          cfgs = Enum.flat_map(features, fn f -> ["--cfg", ~s|feature="#{f}"|] end) ++ build_cfgs

          ok =
            Enum.reduce_while(editions, false, fn ed, _ ->
              File.rm(cdst)

              mr.([rel_src, "--crate-name", crate_id(name), "--crate-type", dep_crate_type, "-o", rlib_rel,
                   "-L", ctx.o_rel, "-L", "#{ctx.o_rel}/deps"] ++ sub_externs ++
                  ["--out-dir", "#{ctx.o_rel}/deps", "--target", dep_target, "--edition", ed] ++ cfgs ++ ctx.cfgs)

              if File.regular?(cdst), do: {:halt, true}, else: {:cont, false}
            end)

          if ok, do: {:halt, true}, else: {:cont, false}
        end)

      if compiled? do
        cl.(["clang"] ++ ctx.clang_flags ++ ["-c", "/work/#{ctx.o_rel}/deps/lib#{name}.rlib.c", "-o", obj_guest])
        if File.regular?(obj_host) do
          # wb-v3d: drop marker files so the post-ensure_deps pass can route proc-macros without
          # threading pm-state through the whole dep recursion. `.pmonly` = this object is in a
          # proc-macro subtree (spoof? compile) → keep it OUT of the final runtime link and IN the
          # server wasm. `.pmentry` = this object IS a proc-macro crate the user externs → build a
          # server wasm + a `<server>.hir` from its rlib metadata.
          if spoof?, do: File.touch!(obj_host <> ".pmonly")

          if pm? do
            File.write!(obj_host <> ".pmentry", "#{crate_id(name)}\t#{rlib_rel}")
            # A proc-macro crate-type build throws (gcc spawn) before writing the .rlib stub, but
            # --extern still needs the file present (mrustc reads the HIR from <rlib>.hir). Touch it.
            File.touch!(String.replace_suffix(obj_host, ".o", ""))
          end
          {:ok, rlib_rel, obj_guest, Enum.uniq(sub_objs)}
        else
          {:error, {:dep_cc_failed, name, version}}
        end
      else
        {:error, {:dep_compile_failed, name, version}}
      end
    end
  end

  defp build_subdeps(subdeps, mrdir, o, mr, cl, feats, pm_ctx?, ctx) do
    Enum.reduce_while(subdeps, {:ok, [], []}, fn {sn, sreq}, {:ok, ex, objs} ->
      case compile_dep(sn, sreq, mrdir, o, mr, cl, feats, false, pm_ctx?, ctx) do
        {:ok, srlib, sobj, sub_objs} -> {:cont, {:ok, ex ++ ["--extern", "#{crate_id(sn)}=#{srlib}"], objs ++ [sobj | sub_objs]}}
        {:error, _} = e -> {:halt, e}
      end
    end)
  end

  # wb-vqx (wb-zq4 gap #1): the target spec used to compile proc-macro crates. Identical to mrustc's
  # built-in wasm32-wasi EXCEPT os-name=linux, so syn's `not(all(wasm32, os in (unknown,wasi)))`
  # guard around the parse_macro_input module evaluates true and the #[macro_export] macro registers.
  # arch stays wasm32 (pointer-bits/atomics/alignments verbatim) and codegen still emits wasm32-wasi,
  # so the produced object is ABI-identical to the normal lane — only the compile-time target_os cfg
  # differs, which only the token-manipulation proc-macro subtree observes. Written once, cached.
  @pm_target_spec ~S"""
  [target]
  family = ""
  os-name = "linux"
  env-name = ""

  [backend.c]
  variant = "gnu"
  emulate-i128 = true
  target = "wasm32-wasi"
  compiler-opts = ["-ffunction-sections",]
  linker-opts-pre = []
  linker-opts-post = ["-Wl,--gc-sections",]

  [arch]
  name = "wasm32"
  pointer-bits = 32
  is-big-endian = false
  has-atomic-u8 = true
  has-atomic-u16 = false
  has-atomic-u32 = true
  has-atomic-u64 = false
  has-atomic-ptr = true
  alignments = { u16 = 2, u32 = 4, u64 = 8, u128 = 16, f32 = 4, f64 = 8, ptr = 4 }
  """
  defp ensure_pm_target_spec(o) do
    rel = "output-wasi-174/wasm32pm.spec"
    abs = Path.join(o, "wasm32pm.spec")
    unless File.regular?(abs), do: File.write!(abs, @pm_target_spec)
    rel
  end

  # Remove a half-built dep's transient outputs so the next fallback version starts clean.
  defp clean_dep_artifacts(o, name) do
    for f <- Path.wildcard(Path.join(o, "deps/lib#{name}.rlib*")), do: File.rm(f)
  end

  # Resolve a version requirement against the crates.io sparse index → {:ok, [{version, deps}]}.
  # deps = [{name, req}] for kind=="normal" deps that are either non-optional OR an optional dep
  # ACTIVATED by the caller's enabled features (cargo feature resolution, e.g. serde "derive" →
  # serde_derive). `enabled` is the caller's feature list for this crate, or nil (→ the crate's
  # own `default` feature set from the index).
  defp resolve_via_index(name, req, enabled \\ nil) do
    url = "https://index.crates.io/#{index_path(name)}"

    case http_get(url) do
      {:ok, body} ->
        cands =
          body
          |> String.split("\n", trim: true)
          |> Enum.flat_map(fn line ->
            case Jason.decode(line) do
              {:ok, %{"vers" => v, "yanked" => false} = m} ->
                case parse_semver(v) do
                  {:ok, sv} -> if semver_req_match?(sv, req), do: [{sv, v, m["deps"] || [], m["features"] || %{}}], else: []
                  _ -> []
                end

              _ ->
                []
            end
          end)

        # Order to TRY: the exact requested version first (what the crate author tested + most
        # likely mrustc-1.54-compatible), then newest-first as fallback. Newest-first alone is
        # the WRONG order under the ceiling — newer releases pull restructured deps (e.g. serde
        # 1.0.2xx → proc-macro2) or use post-1.54 syntax, and the cap never reaches the older one.
        exact = req |> String.trim() |> String.trim_leading("=")
        sorted = Enum.sort_by(cands, fn {sv, _, _, _} -> sv end, :desc)

        # wb-ctk: CEILING-AWARE ORDERING. For crates whose newest releases exceed the mrustc ~1.74
        # ceiling (their dep restructurings / syn-2 / edition-2024), newest-first never reaches a
        # buildable version inside the window. A curated known-good FLOOR is tried first — but ONLY
        # when it satisfies the caller's req (so an explicit `regex@1.10` is untouched; a bare `regex`
        # resolves straight to the buildable floor instead of failing the walk).
        floor = Map.get(@version_floors, name)

        {pinned, others0} =
          Enum.split_with(sorted, fn {_, v, _, _} -> v == exact or (floor && v == floor) end)

        # exact req first, then the floor, then newest-first.
        pinned = Enum.sort_by(pinned, fn {_, v, _, _} -> {v == exact, v == floor} end, :desc)
        {req_first, rest} = {pinned, others0}

        ranked =
          (req_first ++ rest)
          |> Enum.take(6)
          |> Enum.map(fn {_, vstr, deps, features} ->
            # cargo feature resolution: an optional dep is pulled iff its name is in the closure of
            # the caller's ENABLED features. Only when the caller passed explicit features (e.g.
            # serde→[std,derive]); a default-feature build pulls no optional deps, exactly as before
            # (conservative — never silently add a dep that might not compile on the ceiling).
            active = if enabled, do: feature_closure(enabled, features), else: MapSet.new()

            want =
              deps
              |> Enum.filter(fn d ->
                d["kind"] == "normal" and (d["optional"] != true or MapSet.member?(active, d["name"]))
              end)
              |> Enum.map(fn d -> {d["name"], d["req"]} end)
              |> Enum.uniq()

            {vstr, want}
          end)

        if ranked == [], do: {:error, {:no_matching_version, name, req}}, else: {:ok, ranked}

      {:error, reason} ->
        {:error, {:index_fetch_failed, name, String.slice(inspect(reason), 0, 150)}}
    end
  end

  # Pure-Erlang HTTPS GET (:httpc) with VERIFIED TLS via the OS trust store — replaces the curl
  # binary in the compile path (wb-ova). Follows redirects (static.crates.io). Returns {:ok, body}.
  defp http_get(url) do
    :inets.start()
    :ssl.start()

    ssl_opts = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)],
      depth: 3
    ]

    req = {String.to_charlist(url), []}
    http_opts = [ssl: ssl_opts, timeout: 30_000, connect_timeout: 15_000, autoredirect: true]

    case :httpc.request(:get, req, http_opts, body_format: :binary) do
      {:ok, {{_v, 200, _}, _headers, body}} -> {:ok, body}
      {:ok, {{_v, code, _}, _headers, _body}} -> {:error, {:http_status, code}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Transitive closure of enabled cargo features → the set of activated feature/dep names. Each
  # enabled name may be a feature (expands via the `features` map) and/or an optional-dep name; we
  # add both the raw token and its dep base (stripping `dep:`, a `/feature` suffix, and weak `?`).
  # An optional dep is activated when its name lands in this set (handles serde "derive" → serde_derive).
  defp feature_closure(enabled, features), do: fc(enabled, features, MapSet.new())

  defp fc([], _features, acc), do: acc

  defp fc([f | rest], features, acc) do
    if MapSet.member?(acc, f) do
      fc(rest, features, acc)
    else
      base = f |> String.replace_prefix("dep:", "") |> String.split("/") |> hd() |> String.trim_trailing("?")
      acc = acc |> MapSet.put(f) |> MapSet.put(base)
      fc(Map.get(features, f, []) ++ rest, features, acc)
    end
  end

  # crates.io sparse-index path: 1/2/3-char names have special prefixes; else first2/next2/name.
  defp index_path(name) do
    n = String.downcase(name)

    case String.length(n) do
      1 -> "1/#{n}"
      2 -> "2/#{n}"
      3 -> "3/#{String.at(n, 0)}/#{n}"
      _ -> "#{String.slice(n, 0, 2)}/#{String.slice(n, 2, 2)}/#{n}"
    end
  end

  defp parse_semver(v) do
    if String.contains?(v, "-") do
      :pre
    else
      base = v |> String.split("+") |> List.first()

      case String.split(base, ".") do
        [a, b, c] ->
          with {x, ""} <- Integer.parse(a), {y, ""} <- Integer.parse(b), {z, ""} <- Integer.parse(c),
               do: {:ok, {x, y, z}},
               else: (_ -> :bad)

        _ ->
          :bad
      end
    end
  end

  # Match a {maj,min,pat} version against a Cargo req. Handles the dominant forms: caret (bare /
  # ^), exact (=), tilde (~), wildcard (*). For comma-ranges / comparators it caret-matches the
  # first version token (best-effort) — covers the vast majority of crates.io reqs.
  defp semver_req_match?(ver, req) do
    r = req |> String.trim() |> String.split(",") |> List.first() |> String.trim()

    cond do
      r in ["*", ""] -> true
      String.starts_with?(r, "=") -> semver_eq(ver, String.trim_leading(r, "="))
      String.starts_with?(r, "~") -> semver_tilde(ver, String.trim_leading(r, "~"))
      String.starts_with?(r, "^") -> semver_caret(ver, String.trim_leading(r, "^"))
      String.starts_with?(r, ">") or String.starts_with?(r, "<") -> semver_caret(ver, strip_cmp(r))
      true -> semver_caret(ver, r)
    end
  end

  defp strip_cmp(r), do: r |> String.replace(~r/^[<>=]+/, "") |> String.trim()

  # parse a possibly-partial "x", "x.y", "x.y.z" requirement into {maj,min,pat,specified_count}
  defp req_parts(s) do
    nums =
      s |> String.trim() |> String.split(".")
      |> Enum.map(fn p -> case Integer.parse(p) do {n, _} -> n; _ -> nil end end)

    case nums do
      [a | _] when is_integer(a) ->
        {a, Enum.at(nums, 1) || 0, Enum.at(nums, 2) || 0, Enum.count(nums, &is_integer/1)}

      _ ->
        :bad
    end
  end

  defp semver_eq({x, y, z}, r) do
    case req_parts(r) do
      {a, b, c, n} ->
        (n < 1 or x == a) and (n < 2 or y == b) and (n < 3 or z == c)

      _ ->
        false
    end
  end

  defp semver_caret({x, y, z}, r) do
    case req_parts(r) do
      {a, b, c, _} ->
        ge = {x, y, z} >= {a, b, c}
        # upper bound = bump the leftmost non-zero component of the requirement
        lt =
          cond do
            a > 0 -> x == a and {y, z} >= {b, c}
            b > 0 -> x == 0 and y == b and z >= c
            true -> x == 0 and y == 0 and z >= c
          end

        ge and lt

      _ ->
        false
    end
  end

  defp semver_tilde({x, y, z}, r) do
    case req_parts(r) do
      {a, b, c, n} when n >= 2 -> x == a and y == b and z >= c
      {a, _, _, 1} -> x == a
      _ -> false
    end
  end

  # Fetch + extract a crate from the static CDN; return {:ok, lib_rs_path, default_features, edition}.
  defp fetch_crate(name, version, into_dir) do
    File.mkdir_p!(into_dir)
    url = "https://static.crates.io/crates/#{name}/#{name}-#{version}.crate"
    tarball = Path.join(into_dir, "#{name}-#{version}.crate")

    # Pure-Erlang fetch + extract — no curl/tar binaries (wb-ova). :erl_tar handles the gzipped
    # .crate (a tar.gz) in-process.
    with {:ok, body} <- http_get(url),
         :ok <- File.write(tarball, body),
         :ok <- :erl_tar.extract(String.to_charlist(tarball), [:compressed, {:cwd, String.to_charlist(into_dir)}]) do
      cdir = Path.join(into_dir, "#{name}-#{version}")
      lib_rs = Enum.find([Path.join(cdir, "src/lib.rs"), Path.join(cdir, "lib.rs")], &File.regular?/1)
      cargo = Path.join(cdir, "Cargo.toml")

      cond do
        is_nil(lib_rs) -> {:error, {:no_lib_rs, name}}
        true -> {:ok, lib_rs, default_features(cargo), crate_edition(cargo), proc_macro_crate?(cargo)}
      end
    else
      {:error, reason} -> {:error, {:fetch_failed, name, version, String.slice(inspect(reason), 0, 200)}}
    end
  end

  # wb-asw: auto-provide the `wb` runtime crate (compilers/rust/wb/lib.rs) so in-sandbox programs can
  # just `use wb;` for BEAM-backed I/O instead of declaring the host externs by hand. Compiled fresh
  # each build (tiny) with the SAME clang flags as the user (so the exception mode matches), into
  # output-wasi-174/. Returns {extern_args, link_objs}. The host_* symbols stay undefined (the caller
  # uses allow_undefined) and resolve at run via RustDock. No-op if the crate source is absent.
  defp wb_runtime(o, mr, cl, clang_flags) do
    # o = …/compilers/rust/mrustc-root/mrustc/output-wasi-174 ; the crate is at …/compilers/rust/wb
    src = Path.join(o |> Path.dirname() |> Path.dirname() |> Path.dirname(), "wb/lib.rs")

    if File.regular?(src) do
      File.cp!(src, Path.join(o, "wbrt.rs"))
      File.rm(Path.join(o, "wbrt.rlib.c"))
      # a stale wbrt.rlib.o would be double-linked by the libstd `*.rlib.o` glob — clear it.
      File.rm(Path.join(o, "wbrt.rlib.o"))

      mr.(["output-wasi-174/wbrt.rs", "--crate-name", "wb", "--crate-type", "rlib",
           "-o", "output-wasi-174/wbrt.rlib", "-L", "output-wasi-174", "--out-dir", "output-wasi-174",
           "--target", "wasm32-wasi", "--edition", "2018"])

      # NB: object is wbrt.o (NOT *.rlib.o) so the libstd `*.rlib.o` link glob doesn't ALSO pick it
      # up — we add it explicitly below; a double-add is a duplicate-symbol link error.
      with true <- File.regular?(Path.join(o, "wbrt.rlib.c")),
           _ <- cl.(["clang"] ++ clang_flags ++ ["-c", "/work/output-wasi-174/wbrt.rlib.c", "-o", "/work/output-wasi-174/wbrt.o"]),
           true <- File.regular?(Path.join(o, "wbrt.o")) do
        {["--extern", "wb=output-wasi-174/wbrt.rlib"], ["/work/output-wasi-174/wbrt.o"]}
      else
        _ -> {[], []}
      end
    else
      {[], []}
    end
  end

  # wb-5bv: inject `use <derive_crate>::<Derive>` for re-exported derives the user invokes. Reads the
  # proc-macro crates actually built (.pmentry markers), and for each that re-exports derives, adds
  # the direct import IF the derive is used and not already imported from that crate. Pure source
  # transform — makes `use serde::Serialize; #[derive(Serialize)]` resolve without a compiler change.
  defp inject_reexport_imports(src_path, o) do
    if File.regular?(src_path) do
      pm_crates =
        Path.wildcard(Path.join(o, "deps/*.rlib.o.pmentry"))
        |> Enum.map(fn m -> File.read!(m) |> String.split("\t", parts: 2) |> hd() end)

      src = File.read!(src_path)

      injections =
        for pm <- pm_crates,
            derives = Map.get(@derive_reexports, pm),
            derives != nil,
            d <- derives,
            Regex.match?(~r/#\[derive\([^\]]*\b#{d}\b[^\]]*\)\]/, src),
            not Regex.match?(~r/use\s+#{pm}::(\{[^}]*\b#{d}\b|#{d}\b)/, src),
            uniq: true do
          "use #{pm}::#{d};"
        end

      if injections != [] do
        File.write!(src_path, Enum.join(Enum.uniq(injections), "\n") <> "\n" <> src)
      end
    end
  end

  # wb-yq0: BEAM-offload of build scripts — compile + RUN a crate's build.rs IN-SANDBOX and return
  # the `cargo:rustc-cfg` flags it emits (the same orchestrate pattern as proc-macros).
  # SECURITY: build.rs is untrusted. It runs in the wasm sandbox (no escape/exfiltration), is
  # wall-clock bounded (run_wasm_bounded), and we ALLOWLIST its output — only `cargo:rustc-cfg=<safe>`
  # is honored (a validated cfg identifier or key="value"), passed to mrustc as a SINGLE arg (no
  # shell, no flag injection). Link directives, env, and arbitrary `cargo:` lines are IGNORED.
  # Scope: std-only scripts that emit cfgs. A script needing build-dependencies or post-1.74 syntax
  # fails to compile and yields [] — a strict improvement over silently skipping build.rs.
  defp build_script_flags(name, lib_rs, o, mr, cl) do
    cdir = Path.dirname(Path.dirname(lib_rs))
    build_rs = Path.join(cdir, "build.rs")

    if File.regular?(build_rs) do
      bs = "wbbs_#{crate_id(name)}"
      rel = Path.relative_to(build_rs, Path.dirname(o))
      cfile = Path.join(o, "deps/#{bs}.c")
      File.rm(cfile)

      mr.([rel, "--crate-name", bs, "--crate-type", "bin", "-L", "output-wasi-174",
           "-L", "output-wasi-174/deps", "--out-dir", "output-wasi-174/deps",
           "--target", "wasm32-wasi", "--edition", "2018"])

      if File.regular?(cfile) do
        cl.(["clang"] ++ @rust_clang_flags ++ ["-c", "/work/output-wasi-174/deps/#{bs}.c", "-o", "/work/output-wasi-174/deps/#{bs}.o"])

        if File.regular?(Path.join(o, "deps/#{bs}.o")) do
          libstd = Path.wildcard(Path.join(o, "*.rlib.o")) |> Enum.map(&"/work/output-wasi-174/#{Path.basename(&1)}")

          cl.(["wasm-ld", "-m", "wasm32", "-L/usr/lib/wasm32-unknown-wasip1", "-L/usr/lib/wasm32-wasip1",
               "/usr/lib/wasm32-wasip1/crt1-command.o", "/work/output-wasi-174/deps/#{bs}.o"] ++ libstd ++
              ["/work/output-wasi-174/wasi_shim.o", "/work/output-wasi-174/ustub.o", "-lc", "-lsetjmp",
               "/usr/lib/wasm32-unknown-wasip1/libclang_rt.builtins.a", "-o", "/work/output-wasi-174/deps/#{bs}.wasm"])

          wasm = Path.join(o, "deps/#{bs}.wasm")
          if File.regular?(wasm), do: run_build_script(wasm, o), else: []
        else
          []
        end
      else
        []
      end
    else
      []
    end
  end

  defp run_build_script(wasm, o) do
    out_dir = Path.join(o, "deps/wbbs_out")
    File.mkdir_p!(out_dir)

    env = ~w(OUT_DIR=/out TARGET=wasm32-wasi HOST=wasm32-wasi PROFILE=release OPT_LEVEL=1
             CARGO_CFG_TARGET_ARCH=wasm32 CARGO_CFG_TARGET_OS=wasi CARGO_CFG_TARGET_POINTER_WIDTH=32)

    case Workbooks.ProcMacroHost.run_wasm_bounded(wasm, [], dirs: ["#{out_dir}::/out"], env: env, exec_timeout_ms: 30_000) do
      {out, 0} -> parse_build_cfgs(out)
      _ -> []
    end
  end

  # ALLOWLIST: only `cargo:rustc-cfg=` (and the newer `cargo::` form). Everything else is dropped.
  defp parse_build_cfgs(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      cond do
        String.starts_with?(line, "cargo:rustc-cfg=") -> validate_cfg(String.replace_prefix(line, "cargo:rustc-cfg=", ""))
        String.starts_with?(line, "cargo::rustc-cfg=") -> validate_cfg(String.replace_prefix(line, "cargo::rustc-cfg=", ""))
        true -> []
      end
    end)
  end

  # A cfg is honored only if it's a bare identifier or `ident="safe-value"` — no spaces, no shell or
  # arg metacharacters, nothing that could smuggle a second flag. Passed to mrustc as one arg.
  defp validate_cfg(raw) do
    raw = String.trim(raw)

    cond do
      Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, raw) -> ["--cfg", raw]
      Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*="[A-Za-z0-9_.\- ]*"$/, raw) -> ["--cfg", raw]
      true -> []
    end
  end

  # wb-zq4: proc-macro crate? ([lib] proc-macro = true). Such crates `extern crate proc_macro;`
  # (the compiler-provided crate, in the std chain) → need --extern proc_macro at build.
  defp proc_macro_crate?(cargo) do
    case File.read(cargo) do
      {:ok, body} -> Regex.match?(~r/(?m)^\s*proc-macro\s*=\s*true/, body)
      _ -> false
    end
  end

  # Parse the [features] default = [...] list from Cargo.toml (the enabled-by-default features).
  # Enabled features = the crate's literal `default` list. NOTE: this is intentionally NON-transitive
  # (does not expand default→unicode→unicode-perl). Full feature-closure expansion is more correct
  # per cargo semantics, but for heavy crates (regex) it enables unicode-table / perf features that
  # exceed the mrustc ~1.54 ceiling — regex compiles ONLY with the reduced default set, giving basic
  # patterns (literals/classes/alternation/repetition) but not unicode-perl \d/\w (wb-3ev). Revisit
  # transitive expansion together with a per-dep feature-selection API + a newer compiler (wb-1ec).
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

  # Compile a shared support object (wasi_shim/ustub) into output-wasi-174 once; reused by every
  # Rust compile. Plain C, no -disable-verifier needed (these aren't mrustc-emitted).
  defp ensure_rust_obj(o, name, src, cl) do
    obj = Path.join(o, "#{name}.o")

    unless File.regular?(obj) do
      File.cp!(src, Path.join(o, "#{name}.c"))
      cl.(["clang", "--target=wasm32-wasip1", "--sysroot=/usr", "-O1", "-w",
           "-c", "/work/output-wasi-174/#{name}.c", "-o", "/work/output-wasi-174/#{name}.o"])
    end
  end

  # Threads variant of ensure_rust_obj — compile the shim/ustub for wasm32-wasi-threads (shared-memory
  # atomics) so they link against the threads libc. Built once into output-wasi-174-threads/.
  defp ensure_rust_threads_obj(o, name, src, cl) do
    obj = Path.join(o, "#{name}.o")

    unless File.regular?(obj) do
      File.cp!(src, Path.join(o, "#{name}.c"))
      # wasi_shim.c includes <wasi/wasip1.h>, which the clang sysroot ships ONLY under the
      # wasm32-wasip1 target include dir — the wasm32-wasi-threads target dir has wasip2.h, not
      # wasip1.h. The wasi API decls are target-agnostic, so add the wasip1 include explicitly (the
      # base lane gets it implicitly via --target=wasm32-wasip1). Without it a cold (FORCE-cleared)
      # threads dir fails to build the shim → link error "cannot open …/wasi_shim.o".
      cl.(["clang", "--target=wasm32-wasi-threads", "--sysroot=/usr",
           "-I/usr/include/wasm32-wasip1", "-pthread", "-matomics",
           "-mbulk-memory", "-O1", "-w",
           "-c", "/work/#{@threads_o}/#{name}.c", "-o", "/work/#{@threads_o}/#{name}.o"])
    end
  end

  # Run `wasmtime run <args>` and return its combined output (the sandbox executor).
  defp wasmtime(args) do
    {out, _} = System.cmd("wasmtime", ["run"] ++ Workbooks.PackageManager.wasmtime_cache_args() ++ args, stderr_to_stdout: true)
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
  def js_compile_to_wasm(source_path, opts \\ [], root \\ default_root()) do
    jd = Path.join(root, "js")
    clang = Path.expand(Path.join([root, "clang", "clang-root", "llvm.core.wasm"]))
    csys = Path.expand(Path.join([root, "clang", "clang-root", "sysroot"]))
    qsrc = Path.expand(Path.join(jd, "qjs-root/quickjs-ng"))
    # :dock → link the JsDock harness (env.* host-capability imports → Javy.Net/Javy.VFS, wb-e1x.1);
    # the resulting command MUST run under Workbooks.JsDock (Wasmex), not the bare wasmtime CLI.
    harness_name = if Keyword.get(opts, :dock, false), do: "harness_dock.o", else: "harness.o"
    harness = Path.expand(Path.join(jd, harness_name))
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

  @doc """
  Transpile TypeScript → JavaScript in-sandbox (type-strip via tsc-in-QuickJS), returning the JS
  string. Public wrapper over `ts_transpile` used by the npm dir/inline pipeline (wb-spy.T1.5) to
  turn a TS entry into JS the bundler can consume. Returns {:ok, js} | {:error, reason}.
  """
  def transpile_ts(ts_src, root \\ default_root()) do
    jd = Path.join(root, "js")
    qrun = Path.expand(Path.join(jd, "qjs-run.wasm"))
    tsjob = Path.expand(Path.join(jd, "ts/tsjob.js"))

    unless File.regular?(qrun) and File.regular?(tsjob), do: wasmtime_build_js(jd)

    if File.regular?(qrun) and File.regular?(tsjob),
      do: ts_transpile(ts_src, qrun, tsjob),
      else: {:error, {:ts_toolchain_missing, jd}}
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
      "wasmtime run #{Workbooks.PackageManager.wasmtime_cache_flags()} -W exceptions=y -W max-wasm-stack=134217728 " <>
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

  @bundle_exts ~w(.js .cjs .mjs .json)

  @doc """
  Bundle a project directory (its entry + assembled node_modules/) into a single self-contained
  CommonJS JS string, ENTIRELY in the sandbox (wb-spy.T1.4). Mirrors `ts_transpile`: runs a pure-JS
  bundler (bundle/bundlejob.js) inside qjs-run.wasm, feeding the file tree as a JSON map on stdin
  and reading the bundle on stdout. Zero native execution — no esbuild/rollup/node/bun.

  `entry_rel` is POSIX-relative to `project_dir` (e.g. "index.js"). Returns {:ok, js} | {:error, _}.
  """
  def bundle_dir(project_dir, entry_rel, opts \\ [], root \\ default_root()) do
    # ONE routing point for every bundle caller (wb-feto): esbuild FIRST
    # (esbuild.wasm under wasmtime, JIT'd to native — the ~23-min QuickJS bundle
    # drops to ~0.4s), falling back to the QuickJS bundler when esbuild can't
    # resolve a node CORE module (`--platform=browser` makes builtins ERROR rather
    # than externalize, so an fs/http bundle cleanly takes the slow-but-shimmed
    # dock path). A pure-compute/frontend bundle takes the fast path; a missing
    # esbuild.wasm (old image) also falls back. Output is self-contained JS either
    # way (cjs), compatible with every caller (bundled_js_to_wasm, the dock detect).
    case esbuild_bundle_dir(project_dir, entry_rel, [format: "cjs", extra: ["--platform=browser"]], root) do
      {:ok, js} -> {:ok, js}
      {:error, _} -> bundle_dir_quickjs(project_dir, entry_rel, opts, root)
    end
  end

  defp bundle_dir_quickjs(project_dir, entry_rel, opts, root) do
    jd = Path.join(root, "js")
    qrun = Path.expand(Path.join(jd, "qjs-run.wasm"))
    bundlejob = Path.expand(Path.join(jd, "bundle/bundlejob.js"))

    unless File.regular?(qrun), do: wasmtime_build_js(jd)

    cond do
      not (File.regular?(qrun) and File.regular?(bundlejob)) ->
        {:error, {:bundler_toolchain_missing, jd}}

      true ->
        files = Map.merge(collect_bundle_files(Path.expand(project_dir)), shim_files(jd))
        # :dock → permit the host-brokered fs/http/https shims (run via JsDock); wb-e1x.5.
        dock = Keyword.get(opts, :dock, false)
        payload = Jason.encode!(%{"entry" => entry_rel, "files" => files, "dock" => dock})
        run_bundler(payload, qrun, bundlejob)
    end
  end

  @doc """
  esbuild lane (wb-feto) — bundle/transform a project dir with esbuild compiled to
  `wasip1`, run under `wasmtime` (which JITs it to NATIVE). A multi-file JS/TS/JSX
  bundle that takes ~23 min interpreting in QuickJS (`bundle_dir/4`) runs in
  ~160 ms here: the host's wasm-JIT executing the real compiler, no JS-interp
  layer. Handles JSX/TSX, TS, minify, tree-shake. Unlike the QuickJS lanes, esbuild
  reads the project files DIRECTLY from the mapped dir (no JSON file-map on stdin):
  the project is mapped as the wasm root `/`, the bundle is written to `/out.js`.

  `entry_rel` is POSIX-relative to `project_dir` ("src/main.js"). opts:
  `:format` ("esm"|"cjs"|"iife", default "esm") · `:jsx` ("automatic"|"transform")
  · `:minify` (bool) · `:extra` (raw esbuild flag list). Returns {:ok, js} | {:error, _}.
  """
  def esbuild_bundle_dir(project_dir, entry_rel, opts \\ [], root \\ default_root()) do
    wasm = ensure_esbuild(Path.expand(Path.join([root, "esbuild", "esbuild.wasm"])))
    abs = Path.expand(project_dir)
    out_rel = "__wb_esbuild_out.js"
    out_abs = Path.join(abs, out_rel)

    if not File.regular?(wasm) do
      {:error, {:esbuild_missing, wasm}}
    else
      File.rm(out_abs)

      args =
        ["run"] ++
          Workbooks.PackageManager.wasmtime_cache_args() ++
          ["--dir", "#{abs}::/", wasm, "/" <> entry_rel, "--bundle",
           "--format=" <> Keyword.get(opts, :format, "esm"),
           "--outfile=/" <> out_rel] ++
          esbuild_opts(opts) ++ node_polyfill_extra(abs, root, opts)

      try do
        case System.cmd("wasmtime", args, stderr_to_stdout: true) do
          {_, 0} ->
            case File.read(out_abs) do
              {:ok, js} -> File.rm(out_abs); {:ok, js}
              _ -> {:error, :esbuild_no_output}
            end

          {out, _} ->
            {:error, String.slice(String.trim(out), 0, 400)}
        end
      after
        File.rm(out_abs)
      end
    end
  end

  # Self-heal: esbuild.wasm is a gitignored build artifact (20MB). Build it via its build.sh (native
  # Go, ~8s) if absent — mirrors the JS lane's wasmtime_build_js self-heal. No-ops gracefully when Go
  # isn't available (build.sh exits non-zero), leaving the {:esbuild_missing,…} + QuickJS fallback.
  defp ensure_esbuild(wasm) do
    unless File.regular?(wasm) do
      bsh = Path.join(Path.dirname(wasm), "build.sh")
      if File.regular?(bsh), do: System.cmd("bash", [Path.expand(bsh)], stderr_to_stdout: true)
    end

    wasm
  end

  defp esbuild_opts(opts) do
    jsx = case Keyword.get(opts, :jsx) do
      nil -> []
      v -> ["--jsx=#{v}"]
    end

    min = if Keyword.get(opts, :minify, false), do: ["--minify"], else: []
    jsx ++ min ++ Keyword.get(opts, :extra, [])
  end

  # Node-builtin polyfills for the StarlingMonkey/web-target path. StarlingMonkey is a WHATWG web
  # platform with NO Node builtins, and esbuild won't resolve `path`/`events`/… on its own — so alias
  # each Node builtin (and its `node:`-prefixed form) to a pure-JS polyfill installed on demand, plus a
  # minimal `process`/`global` banner. This is what lets the huge fraction of node-authored npm libraries
  # bundle + run unchanged. `opts[:node_polyfills]` (default off) turns it on. Impure builtins (fs/net/
  # crypto) stay brokered (js_dock / wasi:http) — these are the PURE, self-contained ones.
  @node_polyfills %{
    "path" => "path-browserify",
    "events" => "events",
    "util" => "util",
    "stream" => "stream-browserify",
    "querystring" => "querystring-es3",
    "assert" => "assert",
    "string_decoder" => "string_decoder",
    "url" => "url",
    "buffer" => "buffer",
    "os" => "os-browserify",
    "crypto" => "crypto-browserify"
  }

  @node_banner "globalThis.global=globalThis.global||globalThis;" <>
                 "globalThis.process=globalThis.process||{env:{},argv:[\"node\",\"script\"]," <>
                 "platform:\"wasi\",arch:\"wasm32\",version:\"v18.0.0\",versions:{node:\"18.0.0\"}," <>
                 "cwd:function(){return \"/\"},browser:false," <>
                 "nextTick:function(f){var a=[].slice.call(arguments,1);queueMicrotask(function(){f.apply(null,a)})}};" <>
                 # StarlingMonkey has setTimeout/queueMicrotask but not setImmediate — node libs (streams) need it.
                 "globalThis.setImmediate=globalThis.setImmediate||function(f){var a=[].slice.call(arguments,1);" <>
                 "return setTimeout(function(){f.apply(null,a)},0)};" <>
                 "globalThis.clearImmediate=globalThis.clearImmediate||function(id){return clearTimeout(id)};" <>
                 # MessageChannel: React's scheduler (react-dom/server) references it; StarlingMonkey lacks it.
                 # Minimal queueMicrotask-backed port pair — enough for postMessage-based task scheduling.
                 "globalThis.MessageChannel=globalThis.MessageChannel||function(){var a={onmessage:null},b={onmessage:null};" <>
                 "a.postMessage=function(d){queueMicrotask(function(){if(b.onmessage)b.onmessage({data:d})})};" <>
                 "b.postMessage=function(d){queueMicrotask(function(){if(a.onmessage)a.onmessage({data:d})})};" <>
                 "a.close=b.close=function(){};a.start=b.start=function(){};" <>
                 "a.addEventListener=function(t,f){if(t===\"message\")a.onmessage=f};" <>
                 "b.addEventListener=function(t,f){if(t===\"message\")b.onmessage=f};this.port1=a;this.port2=b;};"

  # Inject `Buffer` as a GLOBAL (libraries use the bare global, not `import {Buffer} from 'buffer'`).
  # esbuild `--inject` rewrites free `Buffer` references to this shim's export of the aliased buffer polyfill.
  @node_inject_shim "export {Buffer} from \"buffer\";\n"
  @node_inject_rel "__wb_node_inject.js"

  defp node_polyfill_extra(abs, _root, opts) do
    if Keyword.get(opts, :node_polyfills, false) do
      # install any polyfill package not already present in the project's node_modules (cached after first)
      specs =
        for {_b, pkg} <- @node_polyfills,
            not File.dir?(Path.join([abs, "node_modules", pkg])),
            do: %{name: pkg, req: "*", pin: nil}

      if specs != [], do: Workbooks.Npm.install_tree(specs, abs)
      File.write!(Path.join(abs, @node_inject_rel), @node_inject_shim)

      aliases = for {b, pkg} <- @node_polyfills, do: "--alias:#{b}=#{pkg}"
      node_aliases = for {b, pkg} <- @node_polyfills, do: "--alias:node:#{b}=#{pkg}"
      aliases ++ node_aliases ++ ["--inject:/#{@node_inject_rel}", "--banner:js=#{@node_banner}"]
    else
      []
    end
  end

  @doc """
  Svelte sibling of `bundle_dir/4` (wb-2ku.5): compile a project dir's `.svelte` components AND
  bundle them into a single self-contained CommonJS JS string, ENTIRELY in the sandbox. Runs the
  Svelte compiler (`svelte/compiler`, required from the project's hoisted node_modules) inside
  qjs-run.wasm via compilers/svelte/sveltejob.js — which is CONCATENATED before bundlejob.js so it
  reuses bundlejob's resolver + `bundle()` (one bundler, one resolver; the lane is a pre-bundle
  transform). css is injected at runtime → exactly ONE output. Zero native execution — no
  node/bun/vite/rollup.

  `entry_rel` is POSIX-relative to `project_dir` (e.g. "src/main.js" or "App.svelte"). The project's
  node_modules must already contain the `svelte` package (the npm lane hoists it; see
  PackageManager). Returns {:ok, js} | {:error, _}.
  """
  def svelte_bundle_dir(project_dir, entry_rel, opts \\ [], root \\ default_root()) do
    jd = Path.join(root, "js")
    sd = Path.join(root, "svelte")
    qrun = Path.expand(Path.join(jd, "qjs-run.wasm"))
    compilejob = Path.expand(Path.join(sd, "svelte_compile.js"))
    esbuild_wasm = Path.expand(Path.join([root, "esbuild", "esbuild.wasm"]))

    unless File.regular?(qrun), do: wasmtime_build_js(jd)

    # FAST PATH (wb-feto): split the COMPILE (QuickJS — svelte/compiler is JS, irreducible) from the
    # BUNDLE (esbuild, native-fast). Falls back to the all-QuickJS sveltejob+bundlejob lane if the
    # compile-only job or esbuild.wasm isn't present, or if the split path errors.
    if File.regular?(qrun) and File.regular?(compilejob) and File.regular?(esbuild_wasm) do
      case svelte_bundle_esbuild(project_dir, entry_rel, opts, root, qrun, compilejob) do
        {:ok, js} -> {:ok, js}
        _ -> svelte_bundle_dir_quickjs(project_dir, entry_rel, opts, root)
      end
    else
      svelte_bundle_dir_quickjs(project_dir, entry_rel, opts, root)
    end
  end

  # Compile .svelte → JS via the compile-only job (QuickJS), write the transformed file-map to a temp
  # dir, then bundle with esbuild (treating .svelte as already-JS). The compiled output imports
  # `svelte/internal`, resolved by esbuild from the node_modules carried in the map.
  defp svelte_bundle_esbuild(project_dir, entry_rel, opts, root, qrun, compilejob) do
    abs = Path.expand(project_dir)
    files = collect_bundle_files(abs) |> Map.merge(collect_svelte_files(abs))

    payload =
      %{"files" => files}
      |> maybe_put("svelteOptions", Keyword.get(opts, :svelte_options))
      |> Jason.encode!()

    with {:ok, json} <- run_bundler(payload, qrun, {File.read!(compilejob), "svelte_compile.js"}),
         {:ok, %{"files" => transformed}} <- Jason.decode(json) do
      tmp = Path.join(System.tmp_dir!(), "svelte-eb-#{:erlang.unique_integer([:positive])}")

      try do
        write_files(tmp, transformed)
        esbuild_bundle_dir(tmp, entry_rel, [format: "cjs", extra: ["--loader:.svelte=js"]], root)
      after
        File.rm_rf(tmp)
      end
    else
      _ -> {:error, :svelte_compile_failed}
    end
  end

  defp write_files(dir, map) do
    for {rel, content} <- map do
      p = Path.join(dir, rel)
      File.mkdir_p!(Path.dirname(p))
      File.write!(p, content)
    end
  end

  defp svelte_bundle_dir_quickjs(project_dir, entry_rel, opts, root) do
    jd = Path.join(root, "js")
    sd = Path.join(root, "svelte")
    qrun = Path.expand(Path.join(jd, "qjs-run.wasm"))
    bundlejob = Path.expand(Path.join(jd, "bundle/bundlejob.js"))
    sveltejob = Path.expand(Path.join(sd, "sveltejob.js"))

    cond do
      not (File.regular?(qrun) and File.regular?(bundlejob) and File.regular?(sveltejob)) ->
        {:error, {:svelte_toolchain_missing, sd}}

      true ->
        abs = Path.expand(project_dir)
        # .svelte sources aren't in @bundle_exts, so collect them alongside the JS/JSON tree.
        files =
          collect_bundle_files(abs)
          |> Map.merge(collect_svelte_files(abs))
          |> Map.merge(shim_files(jd))

        dock = Keyword.get(opts, :dock, false)

        payload =
          %{"entry" => entry_rel, "files" => files, "dock" => dock}
          |> maybe_put("svelteOptions", Keyword.get(opts, :svelte_options))
          |> Jason.encode!()

        # The job script = sveltejob.js ++ bundlejob.js (svelte FIRST: it sets __wbDeferMain before
        # bundlejob's standalone auto-run sees it, registers the pre-bundle hook, then drives main).
        script = File.read!(sveltejob) <> "\n" <> File.read!(bundlejob)
        run_bundler(payload, qrun, {script, "sveltejob.js"})
    end
  end

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)

  # Collect .svelte component sources (the only exts the JS-tree glob in collect_bundle_files skips).
  defp collect_svelte_files(abs) do
    Path.wildcard(Path.join(abs, "**/*.svelte"))
    |> Enum.filter(&File.regular?/1)
    |> Map.new(fn p -> {Path.relative_to(p, abs), File.read!(p)} end)
  end

  # The Node core shims (wb-spy.T2.1/T2.4), injected into the bundle file-map under __shims__/ so
  # the bundler can alias require('events')/require('node:crypto') → these (wb-spy.T2.5). Pure JS.
  defp shim_files(jd) do
    Path.wildcard(Path.join(jd, "shims/*.js"))
    |> Map.new(fn p -> {"__shims__/#{Path.basename(p)}", File.read!(p)} end)
  end

  # Collect every bundleable source the bundler may need (the project's own .js/.json + the whole
  # node_modules/ tree), as %{relpath => content}. One recursive glob covers local nested files and
  # node_modules alike.
  defp collect_bundle_files(abs) do
    Path.wildcard(Path.join(abs, "**/*.{js,cjs,mjs,json}"))
    |> Enum.filter(&File.regular?/1)
    |> Enum.filter(fn p -> Path.extname(p) in @bundle_exts end)
    |> Map.new(fn p -> {Path.relative_to(p, abs), File.read!(p)} end)
  end

  # Run a bundler job in qjs-run.wasm: JSON file-map on stdin → bundled JS on stdout. Same wasmtime
  # invocation shape as ts_transpile (the job's dir is preopened as /w). `job` is either the path to
  # an on-disk job script (the JS lane's bundlejob.js) OR {script_source, name} — the svelte lane
  # passes the CONCATENATED sveltejob.js++bundlejob.js source to run from a throwaway job dir, so the
  # two lanes share this one runner (DRY).
  defp run_bundler(payload, qrun, job) do
    id = Integer.to_string(:erlang.unique_integer([:positive]))

    {jobdir, jobname, cleanup_dir?} =
      case job do
        {script, name} when is_binary(script) ->
          d = Path.join(System.tmp_dir!(), "wbbundle-job-#{id}")
          File.mkdir_p!(d)
          File.write!(Path.join(d, name), script)
          {d, name, true}

        path when is_binary(path) ->
          {Path.dirname(path), Path.basename(path), false}
      end

    sin = Path.join(System.tmp_dir!(), "wbbundle-in-#{id}.json")
    serr = Path.join(System.tmp_dir!(), "wbbundle-err-#{id}.txt")
    File.write!(sin, payload)

    cmd =
      "wasmtime run #{Workbooks.PackageManager.wasmtime_cache_flags()} -W exceptions=y -W max-wasm-stack=134217728 " <>
        "--dir #{esc(jobdir)}::/w #{esc(qrun)} /w/#{jobname} < #{esc(sin)} 2> #{esc(serr)}"

    try do
      {out, _status} = System.cmd("sh", ["-c", cmd], stderr_to_stdout: false)

      cond do
        String.trim(out) != "" -> {:ok, out}
        true -> {:error, {:bundle_failed, String.slice(File.read!(serr), 0, 600)}}
      end
    after
      File.rm(sin)
      File.rm(serr)
      if cleanup_dir?, do: File.rm_rf(jobdir)
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
