defmodule Workbooks.PackageManager.Build do
  @moduledoc """
  The build / resolve lanes: take a component (inline source block or a real
  project dir) and compile it to a runnable WASM command, content-addressed in
  build/cache. Every untrusted-source lane (C/Zig/Rust/JS/TS/Go/Svelte + the
  npm/cargo dep pipelines) runs ENTIRELY in the wasm sandbox — zero native
  compilation (wb-fm0). Split out of `Workbooks.PackageManager`, which delegates
  the public build entry points (tangle, build, build_dir, build_c_dir,
  parse_package_json_deps) here.
  """

  alias Workbooks.PackageManager.Paths

  @cache Paths.cache()

  # cache_key lives in Paths (the shared content-address home); this thin alias keeps the
  # lane bodies reading `cache_key([...])` unchanged.
  defp cache_key(parts), do: Paths.cache_key(parts)

  @doc "Tangle a literate Workbook: build every component → [{name, lang, result}]."
  def tangle(org) when is_binary(org) do
    Workbooks.Workbook.tangle_plan(org)
    |> Map.get("worlds", [])
    |> Enum.flat_map(&components/1)
    |> Enum.map(&build/1)
  end

  defp components(%{"components" => comps} = w),
    do: comps ++ Enum.flat_map(Map.get(w, "workflows", []), &components/1)

  @doc """
  Build one component. Two modes: a `:dir` reference builds a REAL project
  directory with its own manifest (Mode 2); otherwise the inline source block is
  compiled, content-addressed (Mode 1). Returns {name, lang, result}.
  """
  def build(%{"name" => name, "lang" => lang} = comp) do
    result =
      if dir = comp["dir"],
        do: build_dir(dir, lang),
        else: build_inline(lang, comp["src"], comp["deps"] || [])

    {name, lang, result}
  end

  # Rust inline blocks can declare crates.io deps (comp["deps"], e.g. ["fnv@1.0.7"]). They are
  # fetched + compiled in-sandbox and linked (wb-3s8). Other langs ignore deps for now.
  defp build_inline("rust", src, deps) do
    out = Path.join(@cache, "#{cache_key(["rust", src, Enum.join(deps, ",")])}.wasm")

    if File.exists?(out) do
      {:ok, out, :cached}
    else
      File.mkdir_p!(@cache)
      rs = Path.join(@cache, "rust-#{cache_key([src, Enum.join(deps, ",")])}.rs")
      File.write!(rs, src)

      case Workbooks.Compilers.rust_compile_to_wasm(rs, deps: deps) do
        {:ok, wasm, _logs} -> File.cp!(wasm, out); File.rm(wasm); {:ok, out, :built}
        {:error, _} = err -> err
      end
    end
  end

  # Inline JS/TS blocks can declare npm deps (comp["deps"], e.g. ["ms@^2.1.3"]) — synthesize a
  # tiny project dir (index.js + package.json) and route through the dir resolve→bundle pipeline
  # (wb-spy.T1.5), mirroring the rust inline-deps path. In-sandbox, zero native execution.
  defp build_inline(lang, src, deps) when lang in ["js", "ts"] and deps != [] do
    out = Path.join(@cache, "#{cache_key([lang, src, Enum.join(deps, ",")])}.wasm")

    if File.exists?(out) do
      {:ok, out, :cached}
    else
      dir = Path.join(@cache, "npm-inline-#{cache_key([lang, src, Enum.join(deps, ",")])}")
      File.rm_rf(dir)
      File.mkdir_p!(dir)
      ext = if lang == "ts", do: "ts", else: "js"
      File.write!(Path.join(dir, "index.#{ext}"), src)

      File.write!(
        Path.join(dir, "package.json"),
        Jason.encode!(%{"dependencies" => Map.new(deps, &npm_dep_spec/1)})
      )

      build_npm_dir(dir, lang, out)
    end
  end

  defp build_inline(lang, src, deps) do
    out = Path.join(@cache, "#{cache_key([lang, src, Enum.join(deps, ",")])}.wasm")
    if File.exists?(out), do: {:ok, out, :cached}, else: compile(lang, src, out)
  end

  @doc """
  Mode 2 — build a component from a REAL project directory. The dir owns its
  Cargo.toml / package.json; its dependencies are defined THERE, not in Org. We
  just run the native toolchain. (Path is relative to the runtime app dir.)

  Component-aware: a crate that declares `[package.metadata.component]` (it
  targets a WIT world, e.g. `workbooks:engine`) is built with `cargo component`
  into a real Component — the path a Workbook takes. A plain crate stays a
  core module (the tool path).
  """
  # Mode 2 — Rust. Compile a real Rust project dir to a runnable wasm command ENTIRELY in the
  # sandbox (mrustc.wasm → clang.wasm, full std), zero native execution. The dir's entry is
  # src/main.rs (or a lone *.rs). Its Cargo.toml [dependencies] are PARSED and fetched+compiled
  # in-sandbox via the dep pipeline (wb-3s8) — pure-Rust crates.io deps work; proc-macro/codegen-
  # build.rs/too-new crates are the documented frontier. Native cargo is never invoked.
  def build_dir(dir, "rust") do
    abs = Path.expand(dir)
    manifest = Path.join(abs, "Cargo.toml")

    entry =
      cond do
        File.regular?(Path.join(abs, "src/main.rs")) -> Path.join(abs, "src/main.rs")
        File.regular?(Path.join(abs, "src/lib.rs")) -> Path.join(abs, "src/lib.rs")
        true -> List.first(Path.wildcard(Path.join(abs, "**/*.rs")))
      end

    cond do
      is_nil(entry) -> {:error, "no .rs source in #{abs}"}
      true -> rust_to_wasm(entry, Path.join(@cache, "#{cache_key(["rustdir", abs])}.wasm"), parse_cargo_deps(manifest))
    end
  end

  # Parse [dependencies] from a Cargo.toml → ["name@req", …]. Handles `name = "req"` and
  # `name = { version = "req", … }`; skips optional = true, and git/path deps (not fetchable).
  # Mode 2 — JS/TS. Compile a project dir's entry (index.js / index.ts) to a runnable wasm
  # command ENTIRELY in the sandbox via QuickJS-ng (wb-fm0.4) — zero native execution, no bun.
  # TS is type-stripped in-sandbox first (build_ts). A dir whose package.json declares npm
  # dependencies is now resolved+fetched+bundled in-sandbox (wb-spy.T1.5): parse → Npm.install_tree
  # → Compilers.bundle_dir → js lane. node_modules already on disk is trusted (offline); otherwise
  # it's installed from the registry. Still zero native execution — no npm/node/bun.
  def build_dir(dir, lang) when lang in ["js", "ts"] do
    abs = Path.expand(dir)
    out = Path.join(@cache, "#{cache_key([abs])}.wasm")
    ext = if lang == "ts", do: "ts", else: "js"
    entry = Path.join(abs, "index.#{ext}")

    cond do
      not File.regular?(entry) -> {:error, "no index.#{ext} in #{abs}"}
      js_dir_has_deps?(abs) -> build_npm_dir(abs, lang, out)
      lang == "ts" -> build_ts(File.read!(entry), out)
      true -> js_to_wasm(entry, out)
    end
  end

  # Mode 2 — Go. Run a real Go project dir's `main` package ENTIRELY in the sandbox via the
  # yaegi interpreter (yaegi-run.wasm) — zero native execution of user code, no TinyGo
  # (wb-fm0.5). Multiple .go files in the dir's root package are concatenated (their `package`
  # + `import` lines merged) into one source yaegi evaluates. NOTE: external module deps aren't
  # supported in-sandbox yet — a dir with non-stdlib requires returns
  # {:error, {:go_deps_unsupported_in_sandbox, _}}.
  def build_dir(dir, lang) when lang in ["go", "tinygo"] do
    abs = Path.expand(dir)

    cond do
      go_dir_has_deps?(abs) ->
        {:error, {:go_deps_unsupported_in_sandbox, abs}}

      true ->
        case Path.wildcard(Path.join(abs, "*.go")) do
          [] ->
            {:error, "no .go sources in #{abs}"}

          files ->
            case go_to_wasm(merge_go_sources(files), Path.join(@cache, "#{cache_key(["godir", abs])}.wasm")) do
              {:ok, wasm, _} -> {:ok, wasm, :built_dir}
              err -> err
            end
        end
    end
  end

  # Mode 2 — C. Compile a real C project dir (multi-file, its own headers) to a
  # runnable wasm32-wasi command. The compile+link runs ENTIRELY in the sandbox via
  # clang.wasm + wasm-ld (Workbooks.Compilers.compile_c) — zero native execution, so
  # untrusted C source never touches a native toolchain (wb-fm0.1). All *.c under the
  # dir are compiled together (first is the main TU, the rest passed as extra sources).
  def build_dir(dir, "c"), do: build_c_dir(Path.expand(dir), [])

  @doc """
  Build a C project dir in-sandbox with optional extra clang flags (`extra_argv`, e.g. `-DWITH_MAIN`
  to enable a single-file interpreter's CLI, or `-I`/`-D` a tool needs). build_dir(dir,"c") is this
  with no extra flags; the registration lane passes a tool's :cflags here.
  """
  def build_c_dir(abs, extra_argv, include_only \\ [], compile_only \\ []) when is_list(extra_argv) do
    src_exts = ~w(.c .cpp .cc .cxx)
    all_src = Path.wildcard(Path.join(abs, "**/*.{c,cpp,cc,cxx}"))

    # :include_only — .c/.cpp that a DRIVER #includes (amalgamation/single-file libs: wuffs-v0.4.c, the
    # FreeType umbrella's parts, stb). They must be PRESENT (+ their dir -I'd) but NOT compiled standalone
    # (else duplicate symbols / no IMPLEMENTATION) — wb-wun5. So they join the companions, not the sources.
    # :compile_only — the inverse: compile ONLY these basenames (the umbrella TUs), everything else is
    # include_only. Cleaner for amalgam projects with FEW umbrellas + MANY parts (FreeType, HarfBuzz).
    {incl, sources} =
      cond do
        compile_only != [] ->
          {comp, rest} = Enum.split_with(all_src, fn f -> Path.basename(f) in compile_only end)
          {rest, comp}

        true ->
          Enum.split_with(all_src, fn f -> Path.basename(f) in include_only end)
      end

    case sources do
      [] ->
        {:error, "no compilable C/C++ sources in #{abs}"}

      [main | rest] ->
        # Forward EVERY non-source companion (headers + generated includes .inc/.def + data) AND the
        # include_only sources into the guest workdir, structure preserved, so any #include resolves.
        companions =
          (Path.wildcard(Path.join(abs, "**/*"))
           |> Enum.filter(&File.regular?/1)
           |> Enum.reject(fn f -> Path.extname(f) in src_exts end))
          |> Kernel.++(incl)
          |> Enum.map(fn f -> {f, Path.relative_to(f, abs)} end)

        compile_c_in_sandbox(
          main,
          rest,
          Path.join(@cache, "#{cache_key(["cdir", abs, Enum.join(extra_argv, " "), Enum.join(include_only, ","), Enum.join(compile_only, ",")])}.wasm"),
          companions,
          extra_argv,
          abs
        )
    end
  end

  # Mode 2 — Zig. Compile a real Zig project dir to a runnable wasm command ENTIRELY in
  # the sandbox: zig1.wasm (.zig → C) → clang.wasm (C → wasm), zero native execution
  # (wb-fm0.2). The dir's root .zig is the entry (build.zig is not used — single-module).
  def build_dir(dir, "zig") do
    abs = Path.expand(dir)

    entry =
      Path.join(abs, "main.zig")
      |> File.regular?()
      |> if(do: Path.join(abs, "main.zig"), else: List.first(Path.wildcard(Path.join(abs, "*.zig"))))

    cond do
      is_nil(entry) -> {:error, "no .zig source in #{abs}"}
      true -> zig_to_wasm(entry, Path.join(@cache, "#{cache_key(["zigdir", abs])}.wasm"))
    end
  end

  # Mode 2 — Svelte. Compile a project dir's .svelte components AND bundle them into a single
  # runnable wasm command ENTIRELY in the sandbox (wb-2ku.5): the Svelte compiler (from the project's
  # node_modules, resolved+fetched via the same npm lane as JS) runs inside qjs-run.wasm, then the
  # emitted JS is bundled (bundlejob) + compiled (JS lane) → wasm. Zero native execution — no
  # node/bun/vite. Entry: src/main.js, else index.js, else the lone *.svelte (mounted by the bundle).
  def build_dir(dir, "svelte") do
    abs = Path.expand(dir)
    out = Path.join(@cache, "#{cache_key(["sveltedir", abs])}.wasm")

    case svelte_entry(abs) do
      nil -> {:error, "no svelte entry (src/main.js, index.js, or a single *.svelte) in #{abs}"}
      entry_rel -> build_svelte_dir(abs, entry_rel, out)
    end
  end

  def build_dir(_dir, lang), do: {:error, {:unsupported_dir_lang, lang}}

  # The entry the svelte bundle mounts from, POSIX-relative to the project dir.
  defp svelte_entry(abs) do
    cond do
      File.regular?(Path.join(abs, "src/main.js")) -> "src/main.js"
      File.regular?(Path.join(abs, "index.js")) -> "index.js"
      true ->
        case Path.wildcard(Path.join(abs, "**/*.svelte")) do
          [only] -> Path.relative_to(only, abs)
          _ -> nil
        end
    end
  end

  # Svelte sibling of build_npm_dir: ensure the svelte package is installed (npm lane), then
  # compile+bundle the .svelte tree + entry in-sandbox and compile the bundle to a wasm command.
  defp build_svelte_dir(abs, entry_rel, out) do
    with :ok <- ensure_node_modules(abs),
         {:ok, js} <- Workbooks.Compilers.svelte_bundle_dir(abs, entry_rel, dock: true) do
      dock? = js =~ "Javy.VFS" or js =~ "Javy.Net"
      bundled_js_to_wasm(js, out, dock?)
    end
  end

  # ── npm dir/inline pipeline (wb-spy.T1.5) ──────────────────────────────────
  # Resolve → install → bundle → compile, all in-sandbox. Ties together the T1.1-1.4 building
  # blocks. Writes the compiled wasm to `out`.
  defp build_npm_dir(abs, lang, out) do
    with :ok <- ensure_node_modules(abs),
         {:ok, entry_rel} <- prepare_bundle_entry(abs, lang),
         # bundle_dir is now esbuild-first with a QuickJS+shims fallback (wb-feto):
         # a frontend/pure-compute bundle is native-fast; an fs/http bundle takes
         # the shimmed dock path. dock:true still requested so the fallback shims.
         {:ok, js} <- Workbooks.Compilers.bundle_dir(abs, entry_rel, dock: true) do
      dock? = js =~ "Javy.VFS" or js =~ "Javy.Net"
      bundled_js_to_wasm(js, out, dock?)
    end
  end

  # node_modules already present (committed / a prior install) is trusted → no network. Otherwise
  # install the parsed deps from the registry. Transitive/optional failures don't fail the build.
  defp ensure_node_modules(abs) do
    if File.dir?(Path.join(abs, "node_modules")) do
      :ok
    else
      case Workbooks.Npm.install_tree(parse_package_json_deps(abs), abs) do
        {:ok, _} -> :ok
        {:ok, _installed, _errors} -> :ok
        {:error, reason} -> {:error, {:npm_install_failed, reason}}
      end
    end
  end

  # The bundler consumes JS. JS entry is used as-is; a TS entry is transpiled to a sibling
  # index.js (a single TS entry + npm/JS deps works; transitive local *.ts is the documented frontier).
  defp prepare_bundle_entry(_abs, "js"), do: {:ok, "index.js"}

  defp prepare_bundle_entry(abs, "ts") do
    case Workbooks.Compilers.transpile_ts(File.read!(Path.join(abs, "index.ts"))) do
      {:ok, js} -> File.write!(Path.join(abs, "index.js"), js); {:ok, "index.js"}
      err -> err
    end
  end

  defp bundled_js_to_wasm(js, out, dock? \\ false) do
    File.mkdir_p!(@cache)
    tmp = Path.join(@cache, "npmbundle-#{cache_key([js])}.js")
    File.write!(tmp, js)
    r = js_to_wasm(tmp, out, dock?)
    File.rm(tmp)
    r
  end

  # "name@req" / "name" / "@scope/pkg@req" → {name, req} for a synthesized package.json.
  defp npm_dep_spec("@" <> rest) do
    case String.split(rest, "@", parts: 2) do
      [n, r] -> {"@" <> n, r}
      [n] -> {"@" <> n, "*"}
    end
  end

  defp npm_dep_spec(s) do
    case String.split(s, "@", parts: 2) do
      [n, r] -> {n, r}
      [n] -> {n, "*"}
    end
  end

  # Parse [dependencies] from a Cargo.toml → ["name@req", …] for the in-sandbox dep pipeline.
  # Handles `name = "req"` and `name = { version = "req", … }`; skips optional/git/path deps.
  defp parse_cargo_deps(manifest) do
    with true <- File.exists?(manifest),
         body <- File.read!(manifest),
         [_, section] <- Regex.run(~r/^\[dependencies\]\s*\n(.*?)(?=\n\[|\z)/ms, body) do
      section |> String.split("\n", trim: true) |> Enum.flat_map(&parse_dep_line/1)
    else
      _ -> []
    end
  end

  defp parse_dep_line(line) do
    cond do
      m = Regex.run(~r/^\s*([A-Za-z0-9_-]+)\s*=\s*"([^"]+)"\s*$/, line) ->
        [_, n, v] = m
        ["#{n}@#{v}"]

      m = Regex.run(~r/^\s*([A-Za-z0-9_-]+)\s*=\s*\{(.+)\}\s*$/, line) ->
        [_, n, attrs] = m
        ver = Regex.run(~r/version\s*=\s*"([^"]+)"/, attrs)

        cond do
          attrs =~ ~r/optional\s*=\s*true/ -> []
          attrs =~ ~r/\b(git|path)\s*=/ -> []
          ver -> ["#{n}@#{Enum.at(ver, 1)}"]
          true -> []
        end

      true ->
        []
    end
  end

  # Parse npm dependencies for the in-sandbox resolver (wb-spy.T1.1) — the npm analog of
  # parse_cargo_deps. Returns a sorted list of %{name, req, pin}: `req` is the semver range
  # requested in package.json; `pin` is an exact version locked by package-lock.json (the
  # resolver SKIPS network resolution when pin is set) or nil (resolve `req` against the
  # registry). "dependencies" + "devDependencies" form the requested set. Specs using a
  # non-registry protocol (git/file/link/workspace/url/github-shorthand) are dropped — they
  # aren't fetchable from the registry in-sandbox.
  def parse_package_json_deps(dir) do
    abs = Path.expand(dir)
    pj = Path.join(abs, "package.json")

    with true <- File.exists?(pj),
         {:ok, body} <- File.read(pj),
         {:ok, json} <- Jason.decode(body),
         true <- is_map(json) do
      requested =
        Map.merge(
          dep_map(json["dependencies"]),
          dep_map(json["devDependencies"])
        )

      pins = lockfile_pins(abs)

      requested
      |> Enum.flat_map(fn {name, spec} -> npm_dep_entry(name, spec, pins) end)
      |> Enum.sort_by(& &1.name)
    else
      _ -> []
    end
  end

  defp dep_map(m) when is_map(m), do: m
  defp dep_map(_), do: %{}

  # One requested dep → [] (skipped) or [entry]. Only string version specs are
  # registry-fetchable; protocol-prefixed/shorthand refs are dropped.
  defp npm_dep_entry(name, spec, pins) when is_binary(spec) do
    if npm_unfetchable?(spec),
      do: [],
      else: [%{name: name, req: spec, pin: Map.get(pins, name)}]
  end

  defp npm_dep_entry(_name, _spec, _pins), do: []

  # Specs the registry resolver cannot handle: protocol-prefixed (git+/git:/file:/link:/
  # workspace:/http(s):/github:) or "owner/repo" GitHub shorthand.
  defp npm_unfetchable?(spec) do
    spec =~ ~r{^(git\+|git:|file:|link:|workspace:|https?:|github:|[\w.-]+/[\w.-]+(#|$))}
  end

  # Exact version pins from package-lock.json. Supports lockfileVersion 2/3 ("packages"
  # keyed by "node_modules/<name>") and v1 ("dependencies" map). Returns %{name => version}.
  # Missing/unparseable lockfile → %{} (everything resolves by range).
  defp lockfile_pins(abs) do
    lock = Path.join(abs, "package-lock.json")

    with true <- File.exists?(lock),
         {:ok, body} <- File.read(lock),
         {:ok, json} <- Jason.decode(body) do
      cond do
        is_map(json["packages"]) -> pins_from_v3(json["packages"])
        is_map(json["dependencies"]) -> pins_from_v1(json["dependencies"])
        true -> %{}
      end
    else
      _ -> %{}
    end
  end

  # v2/v3: "packages" keyed by "" (root) and "node_modules/<name>" (possibly nested
  # ".../node_modules/<name>"). The package name is the segment after the LAST "node_modules/"
  # (greedy match), so scoped (@scope/pkg) and nested deps resolve correctly. When a name
  # appears at multiple depths, the SHALLOWEST (top-level) version wins.
  defp pins_from_v3(packages) do
    packages
    |> Enum.flat_map(fn
      {"", _} ->
        []

      {path, meta} when is_map(meta) ->
        case Regex.run(~r{.*node_modules/(.+)$}, path) do
          [_, name] ->
            depth = length(String.split(path, "node_modules/")) - 1

            case meta["version"] do
              v when is_binary(v) -> [{name, v, depth}]
              _ -> []
            end

          _ ->
            []
        end

      _ ->
        []
    end)
    |> Enum.sort_by(fn {_n, _v, depth} -> -depth end)
    |> Map.new(fn {n, v, _depth} -> {n, v} end)
  end

  # v1: nested "dependencies" map; each value has "version" and may nest its own
  # "dependencies". Walk recursively; the shallower (top-level) version wins.
  defp pins_from_v1(deps) do
    Enum.reduce(deps, %{}, fn {name, meta}, acc ->
      acc =
        if is_map(meta) and is_binary(meta["version"]),
          do: Map.put_new(acc, name, meta["version"]),
          else: acc

      if is_map(meta) and is_map(meta["dependencies"]),
        do: Map.merge(pins_from_v1(meta["dependencies"]), acc),
        else: acc
    end)
  end

  # A package.json with a non-empty "dependencies" needs a bundler + registry the in-sandbox
  # single-file JS lane doesn't do yet. A dep-free single-file project is fine.
  defp js_dir_has_deps?(abs) do
    pj = Path.join(abs, "package.json")
    File.exists?(pj) and Regex.match?(~r/"dependencies"\s*:\s*\{\s*"/, File.read!(pj))
  end

  # A go.mod that `require`s a non-stdlib module needs dep fetching the in-sandbox yaegi lane
  # doesn't do. A stdlib-only program (no require block, or only the module/go lines) is fine.
  defp go_dir_has_deps?(abs) do
    mod = Path.join(abs, "go.mod")
    File.exists?(mod) and Regex.match?(~r/^\s*require\s/m, File.read!(mod))
  end

  # Merge a Go package's files into one source yaegi can eval: keep the first file's `package`
  # clause, collect every import, and concatenate the bodies (minus their package/import lines).
  defp merge_go_sources([single]), do: File.read!(single)

  defp merge_go_sources(files) do
    bodies = Enum.map(files, &File.read!/1)
    pkg = Enum.find_value(bodies, "package main", fn b -> Regex.run(~r/^\s*package\s+\w+/m, b) |> List.first() end)

    imports =
      bodies
      |> Enum.flat_map(fn b -> Regex.scan(~r/^\s*import\s+(?:"[^"]+"|\([^)]*\))/m, b) |> Enum.map(&List.first/1) end)
      |> Enum.uniq()

    stripped =
      Enum.map_join(bodies, "\n", fn b ->
        b
        |> String.replace(~r/^\s*package\s+\w+.*$/m, "")
        |> String.replace(~r/^\s*import\s+(?:"[^"]+"|\([^)]*\))/m, "")
      end)

    "#{pkg}\n#{Enum.join(imports, "\n")}\n#{stripped}\n"
  end

  defp compile("js", src, out), do: build_js(src, out)
  defp compile("ts", src, out), do: build_ts(src, out)
  defp compile("rust", src, out), do: build_rust(src, out)
  defp compile("go", src, out), do: build_go(src, out)
  defp compile("c", src, out) do
    File.mkdir_p!(@cache)
    c = Path.join(@cache, "c-#{cache_key([src])}.c")
    File.write!(c, src)
    compile_c_in_sandbox(c, [], out)
  end

  defp compile("zig", src, out) do
    File.mkdir_p!(@cache)
    z = Path.join(@cache, "zig-#{cache_key([src])}.zig")
    File.write!(z, src)
    zig_to_wasm(z, out)
  end

  defp compile(other, _src, _out), do: {:error, {:unsupported_lang, other}}

  # The mmap emulation shim (file-backed mmap over pread/pwrite), linked into every
  # C/wasi build. wasi-libc's own mmap returns ENOSYS; @mmap_wraps redirect
  # mmap/munmap/msync to the shim's __wrap_* at link time.
  @mmap_shim Path.expand(Path.join([__DIR__, "..", "..", "build", "shims", "mmap_shim.c"]))
  @mmap_wraps ["--wrap=mmap", "--wrap=munmap", "--wrap=msync"]

  # Stubs for host-escape libc fns wasi-libc declares but omits (system/popen/pclose/tmpnam), linked
  # into every C build so real CLIs (Lua's os/io libs, etc.) link and the escape fails safely (wb-nsdc).
  @posix_stub Path.expand(Path.join([__DIR__, "..", "..", "build", "shims", "posix_stub.c"]))

  # C = compile + link to a runnable wasm32-wasip1 command ENTIRELY in the sandbox
  # via clang.wasm + wasm-ld (Workbooks.Compilers.compile_c) — zero native execution
  # (wb-fm0.1). The old native `zig cc`/`wasm-ld` path is gone: untrusted C source is
  # never handed to a native toolchain. `main` is the primary translation unit; `rest`
  # are additional .c sources compiled+linked alongside it. The emitted wasm is copied
  # to `out` (the content-addressed cache path) so the rest of the build path is unchanged.
  #
  # mmap parity: the shim is linked (extra_csrc) and mmap/munmap/msync are --wrap'd to it
  # (ld_args), so a CLI that mmap()s a file works the same as on the old zig-cc lane —
  # now with zero native execution.
  # libc/C-standard header basenames — a project header by one of these names (flatbuffers/string.h)
  # would shadow the real system header if its dir were -I'd; such dirs get -iquote instead (wb-3b3u).
  @libc_header_names ~w(assert.h ctype.h errno.h fenv.h float.h inttypes.h iso646.h limits.h locale.h
                        math.h setjmp.h signal.h stdalign.h stdarg.h stdatomic.h stdbool.h stddef.h
                        stdint.h stdio.h stdlib.h stdnoreturn.h string.h strings.h tgmath.h time.h
                        uchar.h wchar.h wctype.h complex.h)

  defp compile_c_in_sandbox(main, rest, out, headers \\ [], extra_argv \\ [], src_root \\ nil) do
    File.mkdir_p!(@cache)

    # Bring the project's headers into the guest (structure preserved) and add each dir that holds one
    # to the search path, so both `#include "x.h"` and `#include <x.h>` resolve for multi-file tools
    # (wb-yi7q). BUT a dir holding a header named like a libc header (e.g. flatbuffers/string.h) must use
    # -iquote, not -I — else it captures the system `<string.h>` and breaks libc++ <cstring> (wb-3b3u).
    inc_flags =
      headers
      |> Enum.group_by(fn {_host, rel} -> Path.dirname(rel) end, fn {_h, rel} -> Path.basename(rel) end)
      |> Enum.flat_map(fn {d, basenames} ->
        guest = if d in [".", ""], do: "/work", else: "/work/#{d}"
        flag = if Enum.any?(basenames, &(&1 in @libc_header_names)), do: "-iquote", else: "-I"
        [flag, guest]
      end)

    # setjmp/longjmp support (wb-nwd7): lower setjmp via wasm exception-handling. CRUCIAL:
    # -wasm-use-legacy-eh=false emits the MODERN exnref EH (wasmtime 45 supports only that, not the
    # legacy `try` opcode); -lsetjmp links __wasm_setjmp/__wasm_longjmp from the sysroot; the output
    # runs under `-W exceptions=y` (PackageManager.run already passes it). Harmless for code that
    # never uses setjmp — the flags only affect setjmp-using functions; libsetjmp dead-strips if
    # unreferenced. This unblocks the interpreter C cluster (Lua/Forth/Duktape/MuJS/…).
    sjlj = ["-mllvm", "-wasm-enable-sjlj", "-mllvm", "-wasm-use-legacy-eh=false"]

    # wasi-libc "emulated" features many real C tools include (signal.h / process clocks / getpid):
    # each header #errors unless its -D is set, and the symbols come from a sysroot stub lib. Enable
    # them all by default — harmless when unused (headers no-op, libs dead-strip) — so real programs
    # (Lua, interpreters, CLIs) compile without per-tool tweaking.
    emu_defs = ["-D_WASI_EMULATED_SIGNAL", "-D_WASI_EMULATED_PROCESS_CLOCKS", "-D_WASI_EMULATED_GETPID"]
    emu_libs = ["-lwasi-emulated-signal", "-lwasi-emulated-process-clocks", "-lwasi-emulated-getpid"]

    # L_tmpnam: wasi-libc omits it; -D it so call sites using the macro (Lua os.tmpname) compile —
    # the actual tmpnam() is stubbed (posix_stub.c) to fail safely.
    compat_defs = ["-DL_tmpnam=260"]

    # C++ when any source is .cpp/.cc/.cxx → compile as C++ (clang auto-detects per-file by extension +
    # auto-adds the sysroot's libc++ headers) and link libc++/libc++abi. Unlocks the C++ tool class.
    # clang picks C++ per-file by extension (and its default std is c++17), so passing -std=c++17
    # globally is wrong — it errors on the .c shims. Just link libc++/libc++abi when any C++ source is present.
    cpp? = Enum.any?([main | rest], &(Path.extname(&1) in ~w(.cpp .cc .cxx)))

    # C++ exceptions in dir-builds: when the from-source EH runtime is staged, build C++ with the
    # standardized wasm EH and link the EH libc++abi/libunwind — unlocks exception-USING C++ tools
    # (binaryen/DuckDB-class). The no-EH `-lc++abi` only links NON-throwing C++. Shared with compile_cpp
    # via Compilers.cpp_eh_args (one home). Falls back byte-identically to the no-EH path when unstaged.
    {cpp_argv, cpp_libs} =
      cond do
        not cpp? -> {[], []}
        Workbooks.Compilers.cpp_eh_staged?() -> Workbooks.Compilers.cpp_eh_args()
        true -> {[], ["-lc++", "-lc++abi"]}
      end

    opts = [
      extra_csrc: rest ++ [@mmap_shim, @posix_stub],
      aux_files: headers,
      argv: inc_flags ++ sjlj ++ emu_defs ++ compat_defs ++ cpp_argv ++ extra_argv,
      link_libs: ["-lsetjmp"] ++ emu_libs ++ cpp_libs,
      ld_args: @mmap_wraps,
      # stage sources at their paths relative to the project root so unity builds (.c #include'ing a .c,
      # wb-4b61) AND relative-parent includes ("../foo.h", wb-jsc4 / zstd) resolve in the guest.
      src_root: src_root
    ]

    case Workbooks.Compilers.compile_c(main, opts) do
      {:ok, wasm, _logs} ->
        File.cp!(wasm, out)
        File.rm(wasm)
        {:ok, out, :built}

      {:error, _} = err ->
        err
    end
  end

  # Zig = compile a .zig source to a runnable wasm command ENTIRELY in the sandbox via
  # zig1.wasm (.zig → C) → clang.wasm (C → wasm) — zero native execution (wb-fm0.2). The
  # emitted wasm is copied to `out` (the content-addressed cache path).
  defp zig_to_wasm(src, out) do
    File.mkdir_p!(@cache)

    case Workbooks.Compilers.zig_compile_to_wasm(src) do
      {:ok, wasm, _logs} ->
        File.cp!(wasm, out)
        File.rm(wasm)
        {:ok, out, :built}

      {:error, _} = err ->
        err
    end
  end

  # Rust = compile a .rs to a runnable wasm command ENTIRELY in the sandbox via mrustc.wasm →
  # clang.wasm (full std), zero native execution (wb-fm0.3). Copies the emitted wasm to `out`.
  defp rust_to_wasm(src, out, deps \\ []) do
    File.mkdir_p!(@cache)

    case Workbooks.Compilers.rust_compile_to_wasm(src, deps: deps) do
      {:ok, wasm, _logs} ->
        File.cp!(wasm, out)
        File.rm(wasm)
        {:ok, out, :built}

      {:error, _} = err ->
        err
    end
  end

  # Go = run a single-file main package via the yaegi interpreter IN the sandbox (wb-fm0.5).
  defp build_go(src, out), do: go_to_wasm(src, out)

  # yaegi-run.wasm (built once by compilers/go/build.sh — native Go cross-compile, trusted
  # provisioning) + the untrusted Go source EMBEDDED in a `wbgosrc` custom section. The result
  # is a unique, content-addressable, self-contained wasm: run_wasmtime detects the section,
  # extracts the source to a preopen, and yaegi interprets it in-sandbox (zero native execution
  # of user code). The native Go compiler only ever built the trusted runner — never user code.
  @yaegi Path.expand(Path.join([__DIR__, "..", "..", "compilers", "go", "yaegi-root", "yaegi-run.wasm"]))
  @go_build Path.expand(Path.join([__DIR__, "..", "..", "compilers", "go", "build.sh"]))
  @go_magic "WBGOSRC1"

  defp go_to_wasm(src, out) do
    File.mkdir_p!(@cache)

    with :ok <- ensure_yaegi(),
         {:ok, yaegi} <- File.read(@yaegi) do
      File.write!(out, yaegi <> go_src_section(src))
      {:ok, out, :built}
    else
      {:error, _} = err -> err
    end
  end

  # Build yaegi-run.wasm if it isn't present yet (idempotent one-time provisioning).
  defp ensure_yaegi do
    if File.regular?(@yaegi) do
      :ok
    else
      case System.cmd("bash", [@go_build], stderr_to_stdout: true) do
        {_, 0} -> if File.regular?(@yaegi), do: :ok, else: {:error, :yaegi_build_failed}
        {out, _} -> {:error, {:yaegi_build_failed, String.slice(out, -400, 400)}}
      end
    end
  end

  # A wasm custom section "wbgosrc" carrying the Go source, ending in a 16-byte trailer
  # (<source length::big-64> ++ "WBGOSRC1") so run_wasmtime can extract it with one pread.
  # Custom sections are ignored at execution, so the module stays a valid runnable yaegi.
  defp go_src_section(src) do
    name = "wbgosrc"
    payload = src <> <<byte_size(src)::big-64>> <> @go_magic
    body = leb128(byte_size(name)) <> name <> payload
    <<0>> <> leb128(byte_size(body)) <> body
  end

  defp leb128(n) when n < 128, do: <<n>>

  defp leb128(n) do
    import Bitwise
    <<(0x80 ||| (n &&& 0x7F))>> <> leb128(n >>> 7)
  end
  # JS = compile to a runnable wasm command ENTIRELY in the sandbox via QuickJS-ng built to
  # wasm by clang.wasm (wb-fm0.4) — zero native execution, no native javy. The harness keeps
  # the Javy.IO + console contract so existing JS workbooks run unchanged.
  defp build_js(src, out) do
    File.mkdir_p!(@cache)
    js = Path.join(@cache, "js-#{cache_key([src])}.js")
    File.write!(js, src)
    js_to_wasm(js, out)
  end

  defp js_to_wasm(src, out, dock? \\ false) do
    File.mkdir_p!(@cache)

    # dock? → link harness_dock.o (env.host_* imports → Javy.Net/Javy.VFS); the artifact runs via
    # Workbooks.JsDock, detected at run time from its imports (wb-e1x.5).
    case Workbooks.Compilers.js_compile_to_wasm(src, dock: dock?) do
      {:ok, wasm, _logs} ->
        File.cp!(wasm, out)
        File.rm(wasm)
        {:ok, out, :built}

      {:error, _} = err ->
        err
    end
  end

  # TS = transpile TS→JS in-sandbox (the real tsc inside QuickJS) then the JS lane — zero
  # native execution, no bun (wb-fm0.6). Type-strip only (ts.transpileModule).
  defp build_ts(src, out) do
    File.mkdir_p!(@cache)
    ts = Path.join(@cache, "ts-#{cache_key([src])}.ts")
    File.write!(ts, src)

    case Workbooks.Compilers.ts_compile_to_wasm(ts) do
      {:ok, wasm, _logs} ->
        File.cp!(wasm, out)
        File.rm(wasm)
        {:ok, out, :built}

      {:error, _} = err ->
        err
    end
  end

  # Rust = compile a one-file program to a runnable wasm command ENTIRELY in the sandbox via
  # mrustc.wasm (.rs → C) → clang.wasm (C → wasm), linked against the libstd that mrustc.wasm
  # itself prebuilt — zero native execution (wb-fm0.3). The old native `cargo` path is gone:
  # untrusted Rust (incl. hostile proc-macros) never touches a native toolchain. Full std is
  # supported (Vec/iterators/println!). Requires the one-time libstd prebuild
  # (compilers/rust/provision-rust.sh); absent ⇒ {:error, {:libstd_not_prebuilt, _}}.
  defp build_rust(src, out) do
    File.mkdir_p!(@cache)
    rs = Path.join(@cache, "rust-#{cache_key([src])}.rs")
    File.write!(rs, src)
    rust_to_wasm(rs, out)
  end
end
