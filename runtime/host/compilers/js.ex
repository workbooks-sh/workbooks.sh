defmodule Workbooks.Compilers.Js do
  @moduledoc """
  The JS / TS / bundling lanes (wb-fm0.4 / .6, wb-spy, wb-feto, wb-2ku): compile untrusted JS
  to a runnable wasm via QuickJS-ng-built-by-clang, transpile TS in-sandbox via tsc-in-QuickJS,
  and bundle project dirs (esbuild.wasm fast path + QuickJS bundler fallback, svelte, node
  polyfills) — zero native execution. Extracted from the former compilers.ex god-file.
  """
  alias Workbooks.Compilers.Shared
  import Shared, only: [wasmtime: 1, esc: 1]

  # ── JS full lane (wb-fm0.4) ────────────────────────────────────────────────
  # Untrusted JS compiles AND runs entirely in the sandbox via QuickJS-ng built to wasm by
  # clang.wasm (no JIT, no native javy). The work harness (compilers/js/harness.c) supplies the
  # same contract the native-javy lane did — Javy.IO.readSync/writeSync + console — plus a
  # TextEncoder/Decoder polyfill. Recipe: compilers/js/build.sh.
  @js_qobjs ~w(quickjs cutils libregexp libunicode xsum)

  @doc """
  Compile JS source → a runnable wasm command entirely in the sandbox: embed the JS into a C
  byte array (js_src.c), clang.wasm-compile it, and wasm-ld it with the prebuilt harness +
  libquickjs objects. Self-heals the toolchain (compilers/js/build.sh) if the objects are
  absent. Returns {:ok, wasm_path, log} | {:error, reason}.
  """
  def js_compile_to_wasm(source_path, opts \\ [], root \\ Shared.default_root()) do
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
  def ts_compile_to_wasm(source_path, opts \\ [], root \\ Shared.default_root()) do
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
  def transpile_ts(ts_src, root \\ Shared.default_root()) do
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

  @bundle_exts ~w(.js .cjs .mjs .json)

  @doc """
  Bundle a project directory (its entry + assembled node_modules/) into a single self-contained
  CommonJS JS string, ENTIRELY in the sandbox (wb-spy.T1.4). Mirrors `ts_transpile`: runs a pure-JS
  bundler (bundle/bundlejob.js) inside qjs-run.wasm, feeding the file tree as a JSON map on stdin
  and reading the bundle on stdout. Zero native execution — no esbuild/rollup/node/bun.

  `entry_rel` is POSIX-relative to `project_dir` (e.g. "index.js"). Returns {:ok, js} | {:error, _}.
  """
  def bundle_dir(project_dir, entry_rel, opts \\ [], root \\ Shared.default_root()) do
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
  def esbuild_bundle_dir(project_dir, entry_rel, opts \\ [], root \\ Shared.default_root()) do
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
    "crypto" => "crypto-browserify",
    "zlib" => "browserify-zlib",
    # node:fs → memfs in-memory filesystem. Makes the fs API available (writeFileSync/readFileSync/mkdir/
    # readdir/promises) so node-authored libs that read/write a virtual or temp FS run unchanged. NOTE: this
    # is an in-memory FS (fresh per run, no host file access) — real host-FS reads are a separate broker concern.
    "fs" => "memfs"
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
                 "b.addEventListener=function(t,f){if(t===\"message\")b.onmessage=f};this.port1=a;this.port2=b;};" <>
                 # AbortController/AbortSignal: absent on StarlingMonkey; used widely for cancellation/timeouts.
                 "if(typeof AbortController===\"undefined\"){(function(){function S(){this.aborted=false;this.reason=undefined;" <>
                 "this.onabort=null;this._l=[]}S.prototype.addEventListener=function(t,f){if(t===\"abort\")this._l.push(f)};" <>
                 "S.prototype.removeEventListener=function(t,f){var i=this._l.indexOf(f);if(i>=0)this._l.splice(i,1)};" <>
                 "S.prototype.dispatchEvent=function(){return true};function C(){this.signal=new S()}" <>
                 "C.prototype.abort=function(r){var s=this.signal;if(s.aborted)return;s.aborted=true;s.reason=r;" <>
                 "var e={type:\"abort\"};if(s.onabort)s.onabort(e);s._l.slice().forEach(function(f){f(e)})};" <>
                 "S.timeout=function(ms){var c=new C();setTimeout(function(){c.abort(new Error(\"TimeoutError\"))},ms);return c.signal};" <>
                 "S.abort=function(r){var c=new C();c.abort(r);return c.signal};globalThis.AbortSignal=S;globalThis.AbortController=C;})();}"

  # Inject `Buffer` as a GLOBAL (libraries use the bare global, not `import {Buffer} from 'buffer'`).
  # esbuild `--inject` rewrites free `Buffer` references to this shim's export of the aliased buffer polyfill.
  @node_inject_shim "export {Buffer} from \"buffer\";\n"
  @node_inject_rel "__wb_node_inject.js"
  # `fs/promises` subpath → memfs's promises API (the map only aliases the bare `fs` specifier).
  @node_fsp_shim "module.exports = require(\"memfs\").fs.promises;\n"
  @node_fsp_rel "__wb_fs_promises.cjs"

  defp node_polyfill_extra(abs, _root, opts) do
    if Keyword.get(opts, :node_polyfills, false) do
      # install any polyfill package not already present in the project's node_modules (cached after first)
      specs =
        for {_b, pkg} <- @node_polyfills,
            not File.dir?(Path.join([abs, "node_modules", pkg])),
            do: %{name: pkg, req: "*", pin: nil}

      if specs != [], do: Workbooks.Npm.install_tree(specs, abs)
      File.write!(Path.join(abs, @node_inject_rel), @node_inject_shim)
      File.write!(Path.join(abs, @node_fsp_rel), @node_fsp_shim)

      aliases = for {b, pkg} <- @node_polyfills, do: "--alias:#{b}=#{pkg}"
      node_aliases = for {b, pkg} <- @node_polyfills, do: "--alias:node:#{b}=#{pkg}"
      fs_promises = ["--alias:fs/promises=/#{@node_fsp_rel}", "--alias:node:fs/promises=/#{@node_fsp_rel}"]
      aliases ++ node_aliases ++ fs_promises ++ ["--inject:/#{@node_inject_rel}", "--banner:js=#{@node_banner}"]
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
  def svelte_bundle_dir(project_dir, entry_rel, opts \\ [], root \\ Shared.default_root()) do
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
end
