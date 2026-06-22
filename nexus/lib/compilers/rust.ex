defmodule Nexus.Compilers.Rust do
  @moduledoc """
  The Rust full-std lane (wb-fm0.3) + the crates.io dependency machinery: compile untrusted
  Rust (full std, real crates.io deps, proc-macros, build.rs, threads) → a runnable wasm
  ARTIFACT entirely in the sandbox — mrustc.wasm (.rs → C) → clang.wasm (C → .o) → wasm-ld,
  zero native execution. Extracted from the former compilers.ex god-file.

  Recipe + walls: compilers/rust/{PORT-LOG.md,BUILD-STATE.md,std/std-e2e.sh}.
  """
  alias Nexus.Compilers.Shared
  import Shared, only: [wasmtime: 1, http_get: 1]

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

  # wb-346: curated reduced-feature sets tried first in the :reduce fallback for crates whose full
  # default exceeds the mrustc ceiling but a middle set keeps key capability. List-of-feature-sets.
  @feature_hints %{
    "regex" => [["std", "unicode-perl"]],
    "regex-syntax" => [["std", "unicode-perl"]]
  }

  # wb-5bv: mrustc can't resolve a RE-EXPORTED proc-macro derive (`use serde::Serialize` →
  # serde's `pub use serde_derive::*`). Rather than fork the compiler, the BEAM normalizes the
  # SOURCE: when a proc-macro crate that re-exports derives is in the tree and the user invokes one
  # of those derives, inject `use <derive_crate>::<Derive>` — which coexists with the user's
  # `use serde::Serialize` (trait = type namespace, derive = macro namespace; verified). Keyed by
  # the derive crate (crate_id form) → the derive names it provides.
  @derive_reexports %{
    "serde_derive" => ~w(Serialize Deserialize)
  }

  # wb-ctk: known-good version FLOORS for crates whose newest releases exceed the mrustc ~1.74
  # ceiling (newer regex pulls regex-automata; syn/serde_derive went to syn-2 / edition-2024). The
  # resolver tries the floor FIRST when it satisfies the caller's req, so a bare `regex` resolves to
  # a buildable version instead of walking 6 doomed newest ones. An explicit pin still wins.
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
  Compile untrusted Rust (full std) → a runnable wasm ARTIFACT entirely in the sandbox:
  mrustc.wasm (.rs → C) → clang.wasm (C → .o) → wasm-ld (link against the libstd that was
  prebuilt BY mrustc.wasm, plus wasi_shim + the _Unwind_Resume stub) — zero native execution.

  Requires the one-time libstd prebuild (compilers/rust/std/prebuild-libstd.sh, driven by
  provision-rust.sh). If it's absent this returns {:error, {:libstd_not_prebuilt, dir}} rather
  than silently shelling a native rustc — the canon is no native compile for untrusted source.
  Returns {:ok, wasm_path, log} | {:error, reason}.
  """
  def rust_compile_to_wasm(source_path, opts \\ [], root \\ Shared.default_root()) do
    case rust_compile_to_wasm_impl(source_path, opts, root) do
      {:error, reason} = err ->
        require Logger
        Logger.warning("[rust] compile failed: " <> (inspect(reason) |> String.slice(0, 240)))
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
        ["-W", "exceptions=y", "--dir", "#{csys}::/usr::ro", "--dir", "#{mrdir}::/work",
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

        # wb-asw: auto-provide the `work` BEAM-runtime crate so programs can `use wb;` (opt-in).
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

            case Nexus.ProcMacroHost.run_mrustc(pm_wasm, user_args, mrdir, env) do
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

              # --export <fn> for each unit function: keeps it from being gc-stripped and surfaces
              # it as a wasm export, so the module can be componentized against a typed WIT world
              # (the new model) instead of only run as a command. Default [] — command lane unchanged.
              exports = Keyword.get(opts, :exports, []) |> Enum.map(&"--export=#{&1}")

              ld =
                ["wasm-ld", "-m", "wasm32", "-L/usr/lib/wasm32-unknown-wasip1", "-L/usr/lib/wasm32-wasip1"] ++
                  au ++ exports ++
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
  def compile_rust_threads(source_path, opts \\ [], root \\ Shared.default_root()) do
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
        ["-W", "exceptions=y", "--dir", "#{csys}::/usr::ro", "--dir", "#{mrdir}::/work",
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
  # and Nexus.ProcMacroHost maps the loaded `lib<crate>.rlib` path → `<crate>_server.wasm` at run
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
  defp resolve_via_index(name, req, enabled) do
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

  # wb-asw: auto-provide the `work` runtime crate (compilers/rust/wb/lib.rs) so in-sandbox programs can
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

    case Nexus.ProcMacroHost.run_wasm_bounded(wasm, [], dirs: ["#{out_dir}::/out"], env: env, exec_timeout_ms: 30_000) do
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
end
