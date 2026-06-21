defmodule Nexus.Compilers.Js do
  @moduledoc """
  The JS lane — QuickJS-ng compiled per-program to a `wasm32-wasi` COMMAND module. The user's JS is
  embedded into `js_src.c` (`wb_js_src`/`wb_js_len`), compiled with `clang.wasm`, and linked against
  the prebuilt `harness.o` (QuickJS host harness: Javy.IO + console + TextEncoder/Decoder) plus the
  `libquickjs` objects (`compilers/js/qjs-root/quickjs-ng/*.o`). The result `main()` evals the
  embedded program and talks stdin→stdout — the SAME command shape as a toolkit (`coreutils.wasm`),
  run via `wasmtime run <wasm>` or Wasmex with WASI stdio.

  The spine for the whole JS family: `ts`/`svelte`/`solid` transpile to JS, then reuse this; the
  `harness_dock.o` variant (caps) adds `env.*` host imports — wired when a unit grants capabilities.
  """
  import Nexus.Compilers.Shared, only: [wasmtime: 1]

  @qjs_objs ~w(quickjs cutils libregexp libunicode xsum)

  @doc """
  Compile a JS source string to a `wasm32-wasi` command module. `opts[:dock]` (default false) links
  the `harness_dock.o` capability harness instead of the bare `harness.o`. Returns `{:ok, path}` or
  `{:error, reason}`. The toolchain (`compilers/js/`) must be present (qjs objects + harness.o).
  """
  def js_compile_to_wasm(source, opts \\ [], root \\ Nexus.Compilers.Shared.default_root()) do
    jsdir = Path.expand(Path.join(root, "js"))
    clang = Path.expand(Path.join([root, "clang", "clang-root", "llvm.core.wasm"]))
    csys = Path.expand(Path.join([root, "clang", "clang-root", "sysroot"]))
    harness = if Keyword.get(opts, :dock, false), do: "harness_dock.o", else: "harness.o"

    cond do
      not File.regular?(Path.join(jsdir, harness)) ->
        {:error, {:js_toolchain_missing, Path.join(jsdir, harness)}}

      not Enum.all?(@qjs_objs, &File.regular?(Path.join([jsdir, "qjs-root", "quickjs-ng", "#{&1}.o"]))) ->
        {:error, {:js_toolchain_missing, Path.join([jsdir, "qjs-root", "quickjs-ng"])}}

      true ->
        build(source, jsdir, clang, csys, harness)
    end
  end

  defp build(source, jsdir, clang, csys, harness) do
    work = Path.join(System.tmp_dir!(), "nxc_js_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(work, "t"))
    File.write!(Path.join(work, "js_src.c"), embed_c(source))

    cl = fn args ->
      wasmtime([
        "--dir", "#{csys}::/usr", "--dir", "#{work}::/work", "--dir", "#{work}/t::/tmp",
        "--dir", "#{jsdir}::/js", "--env", "TMPDIR=/tmp", clang | args
      ])
    end

    # js_src.c → js_src.o (just two C symbols; no headers needed)
    cl.(["clang", "--target=wasm32-wasip1", "--sysroot=/usr", "-O1", "-w", "-c", "/work/js_src.c", "-o", "/work/js_src.o"])

    qobjs = Enum.map(@qjs_objs, &"/js/qjs-root/quickjs-ng/#{&1}.o")

    link =
      ["wasm-ld", "-m", "wasm32", "-L/usr/lib/wasm32-unknown-wasip1", "-L/usr/lib/wasm32-wasip1",
       "/usr/lib/wasm32-wasip1/crt1-command.o", "/js/#{harness}", "/work/js_src.o"] ++
        qobjs ++
        ["-lc", "/usr/lib/wasm32-unknown-wasip1/libclang_rt.builtins.a", "-o", "/work/u.wasm"]

    cl.(link)

    core = Path.join(work, "u.wasm")

    if File.regular?(core) do
      dest = Path.join(System.tmp_dir!(), "nxc_js_#{System.unique_integer([:positive])}.wasm")
      File.cp!(core, dest)
      File.rm_rf(work)
      {:ok, dest}
    else
      File.rm_rf(work)
      {:error, :js_compile_failed}
    end
  end

  @doc """
  Transpile `source` of `kind` (`:ts` | `:svelte` | `:solid`) to plain JS by running the matching
  job script inside `qjs-run.wasm` (the generic QuickJS interpreter). `:ts` pipes the source on
  stdin (`ts/tsjob.js` → JS on stdout). `:svelte`/`:solid` use a files-map JSON contract
  (`{files: {...}}` in → compiled `{files}` out) so the in-sandbox compiler (vendored, no native
  exec) can resolve its own package. Returns `{:ok, js}` or `{:error, reason}`.
  """
  def transpile(kind, source, root \\ Nexus.Compilers.Shared.default_root())

  def transpile(:ts, source, root) do
    cdir = Path.expand(root)
    qjs = Path.join([cdir, "js", "qjs-run.wasm"])
    job = Path.join([cdir, "js", "ts", "tsjob.js"])

    cond do
      not File.regular?(qjs) -> {:error, {:js_toolchain_missing, qjs}}
      not File.regular?(job) -> {:error, {:transpiler_missing, job}}
      true -> with {:ok, out} <- run_qjs(qjs, cdir, "/c/js/ts/tsjob.js", source), do: {:ok, out}
    end
  end

  def transpile(:svelte, source, root) do
    cdir = Path.expand(root)
    qjs = Path.join([cdir, "js", "qjs-run.wasm"])
    job = Path.join([cdir, "svelte", "svelte_compile.js"])
    compiler = Path.join([cdir, "svelte", "vendor", "compiler.cjs"])

    cond do
      not File.regular?(qjs) -> {:error, {:js_toolchain_missing, qjs}}
      not File.regular?(job) -> {:error, {:transpiler_missing, job}}
      not File.regular?(compiler) -> {:error, {:svelte_compiler_missing, compiler}}
      true -> filemap_compile(qjs, cdir, "/c/svelte/svelte_compile.js", "in.svelte", source, "node_modules/svelte/compiler.cjs", File.read!(compiler))
    end
  end

  def transpile(:solid, source, root) do
    cdir = Path.expand(root)
    qjs = Path.join([cdir, "js", "qjs-run.wasm"])
    job = Path.join([cdir, "solid", "solid_compile.js"])
    babel = Path.join([cdir, "solid", "vendor", "babel.js"])

    cond do
      not File.regular?(qjs) -> {:error, {:js_toolchain_missing, qjs}}
      not File.regular?(job) -> {:error, {:transpiler_missing, job}}
      not File.regular?(babel) -> {:error, {:solid_compiler_missing, babel}}
      true -> filemap_compile(qjs, cdir, "/c/solid/solid_compile.js", "in.jsx", source, "node_modules/@babel/standalone/babel.js", File.read!(babel))
    end
  end

  def transpile(other, _source, _root), do: {:error, {:unknown_transpiler, other}}

  # files-map contract: send {files:{entry, <compiler pkg path>}}, the job compiles each source entry
  # in place and writes {files} back; pull the compiled `entry` out.
  defp filemap_compile(qjs, cdir, guest_job, entry, source, pkg_path, pkg_src) do
    payload = Jason.encode!(%{"files" => %{entry => source, pkg_path => pkg_src}})

    with {:ok, out} <- run_qjs(qjs, cdir, guest_job, payload),
         {:ok, %{"files" => files}} <- Jason.decode(out),
         js when is_binary(js) <- Map.get(files, entry) do
      {:ok, js}
    else
      {:ok, _} -> {:error, :transpile_no_output}
      {:error, %Jason.DecodeError{}} -> {:error, {:transpile_failed, :bad_json}}
      err -> err
    end
  end

  # Run `qjs-run.wasm <guest_job>` with `stdin` fed in (host does only the `< file` redirect; the
  # guest is the sandboxed wasm). The whole compilers dir is mounted at /c. Mirrors Bash.run_wasm.
  defp run_qjs(qjs, cdir, guest_job, stdin) do
    stdin_file = Path.join(System.tmp_dir!(), "nxc_jsin_#{System.unique_integer([:positive])}")
    File.write!(stdin_file, stdin)
    {flags, exec} = Nexus.Wasm.Aot.resolve(qjs)

    inner =
      (["wasmtime", "run"] ++ flags ++ ["--dir", "#{cdir}::/c", exec, guest_job])
      |> Enum.map_join(" ", &shq/1)

    {out, code} = System.cmd("sh", ["-c", "#{inner} < #{shq(stdin_file)}"], stderr_to_stdout: true)
    File.rm(stdin_file)

    if code == 0, do: {:ok, out}, else: {:error, {:transpile_failed, code, String.slice(out, 0, 400)}}
  end

  defp shq(s), do: "'" <> String.replace(to_string(s), "'", "'\\''") <> "'"

  # Embed the program as a C string-literal payload the harness evals. We emit a byte array (not a
  # string literal) to sidestep escaping + length limits.
  defp embed_c(source) do
    bytes = source |> :binary.bin_to_list() |> Enum.map_join(",", &Integer.to_string/1)
    """
    const char wb_js_src[] = {#{bytes}};
    const unsigned wb_js_len = #{byte_size(source)};
    """
  end
end
