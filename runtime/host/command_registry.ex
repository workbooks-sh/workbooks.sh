defmodule Workbooks.CommandRegistry do
  @moduledoc """
  The in-WASM command registry (wb-11ck.21). A *command* is a CLI *converted to a
  runnable WASM module* — stdin in, stdout out — that a Workbook/agent invokes by
  name through the `run-command` Dock import (and, once it lands, the bash-type
  in-WASM shell, wb-11ck.20). The in-WASM equivalent of a CLI on $PATH, except
  the CLI is itself sandboxed WASM. Think jq, ripgrep, grep.

  Relationship to toolkits (L4, ARCHITECTURE.org): a *toolkit* is our version of
  Claude Code skills — a progressive-disclosure skill doc bundled with the whole
  CLI it documents. That CLI is converted to commands (here); the skill tells the
  agent which commands exist and how to call them. So a command is the runnable
  form of a toolkit's CLI; the skill/discovery surface is the separate L4 piece.
  A command may also need a capability (network → `net-fetch` + the secret model);
  that's a property of the command, not a different layer.

  Built-ins are either source compiled on first use (`upper`, Javy) or prebuilt
  wasm artifacts: `jq` (a jaq-interpret wrapper) and `grep` (a regex wrapper),
  both real CLIs compiled to wasm. `oql` is the kernel (a Component), reachable
  directly, not as a stdio command.
  """

  # Built-in shapes (each carries an ARG MODE — the last element):
  #   {:src, lang, code, mode}  compiled on first use
  #   {:wasm, path, mode}       a prebuilt artifact (a real CLI compiled to wasm)
  # Arg mode reconciles two conventions:
  #   :argv   — args passed as real wasmtime argv (the universal CLI ABI). The
  #             default for auto-wrapped upstream CLIs (e.g. sd, ripgrep).
  #   :stdin1 — args become the FIRST stdin line (our legacy jq/grep protocol,
  #             where the binary reads its filter/pattern from line 1 of stdin).
  # wbox: a multicall coreutils (echo/cat/seq/head/wc/…) compiled to wasm on first
  # use — the in-WASM shell's command vocabulary (wb-9ja). Source lives under host/
  # (NOT compilers/, which .dockerignore excludes) so it's in the release build
  # context; embedded here at compile time so it ships with the release.
  @wbox_c_path Path.expand("wbox/wbox.c", __DIR__)
  @external_resource @wbox_c_path
  @wbox_c File.read!(@wbox_c_path)

  @builtins %{
    # A proof command: uppercases stdin. Source-built (Javy) on first use.
    # Chunked read (64 KiB) accumulated until EOF — handles stdin of any size
    # (the old fixed 8 KiB buffer silently truncated larger inputs).
    "upper" =>
      {:src, "js",
       ~S|const CH=65536;const cs=[];let n;const b=new Uint8Array(CH);while((n=Javy.IO.readSync(0,b))>0){cs.push(b.slice(0,n));}let t=0;for(const c of cs)t+=c.length;const all=new Uint8Array(t);let o=0;for(const c of cs){all.set(c,o);o+=c.length;}const s=new TextDecoder().decode(all).trim();Javy.IO.writeSync(1,new TextEncoder().encode(s.toUpperCase()));|,
       :argv},
    # Real jq: a wasi-clean jaq-interpret wrapper compiled to wasm (commands/jq/).
    # Stdin protocol: first line = filter, rest = JSON.
    "jq" => {:wasm, "build/commands/jq.wasm", :stdin1},
    # Real grep: a regex-crate wrapper (commands/grep/). Stdin protocol: first
    # line = pattern, rest = text; matching lines printed. (ripgrep's recursive
    # file walk doesn't fit a stdin command; line-grep is the command form.)
    "grep" => {:wasm, "build/commands/grep.wasm", :stdin1},
    # Multicall coreutils for the in-WASM shell — Workbooks.Shell dispatches
    # echo/cat/seq/head/wc/true/false here as `wbox <applet> …` (wb-9ja).
    "wbox" => {:src, "c", @wbox_c, :argv}
  }

  # Dynamically registered commands live in :persistent_term (rare writes, fast
  # reads, no process needed). The registry is the static built-ins OVERLAID with
  # whatever was registered at runtime — so the command set is NOT a hardcoded
  # list: any wasm CLI can be registered and run through the same generic path.
  @dynamic {__MODULE__, :dynamic_commands}

  # SECURITY (wb-sec): built-in names are RESERVED. A dynamic registration must
  # never shadow jq/grep/upper — otherwise any caller that can reach register/3
  # (or a data-driven `wb toolkit build`) silently hijacks a trusted command for
  # every Instance (semantic supply-chain attack). registry/0 also merges with
  # @builtins LAST so even a stale/poisoned dynamic key cannot win at lookup.
  @reserved Map.keys(@builtins)

  # SECURITY (wb-sec): a registered command name must be a non-empty binary made
  # of a conservative charset. Empty/nil names pollute the namespace and can mask
  # lookup; exotic names are never legitimate command ids.
  @name_re ~r/^[A-Za-z0-9_.-]+$/

  # SECURITY (wb-sec): bound the number of dynamic entries so a registration
  # storm cannot grow the :persistent_term map unboundedly (each put triggers a
  # global GC) — a DoS. 4096 is far above any real command set.
  @max_dynamic 4096

  @doc "Reserved (built-in) command names that may not be dynamically registered."
  def reserved_names, do: @reserved

  @doc """
  All commands: dynamically registered ones OVERLAID with the static built-ins
  (built-ins LAST → built-ins always win). Even if a poisoned dynamic key for a
  built-in name slips in, lookup resolves to the trusted built-in.
  """
  def registry, do: Map.merge(:persistent_term.get(@dynamic, %{}), @builtins)

  @doc "Registered command names (built-ins + dynamic)."
  def list, do: Map.keys(registry())

  @doc """
  The live spec currently bound to `name` (built-in or dynamic), or nil.

  HOT-SWAP (wb-rhs.8): re-registering an existing name (a fresh
  `build_and_register_inline` / `register` with a new content hash) REPLACES the
  binding in place — the next `run` resolves the new artifact, with NO restart.
  Live-update semantics, correct by construction:
    * In-flight calls finish on the OLD bytes — `run` resolves the path at call
      time and the old content-addressed file is never deleted on re-register
      (a new sha is a new file; the old one remains), so a call already in flight
      keeps its artifact. New calls resolve the new entry.
    * Built-in names (jq/grep/upper) are RESERVED and unshadowable — a swap can
      never replace a trusted built-in (registry/0 merges built-ins last).
  Use `current/1` to observe which artifact is live (telemetry / verify a swap).
  """
  def current(name) when is_binary(name), do: Map.get(registry(), name)

  # ── #+TRUST → isolation (wb-pkh.5) ──────────────────────────────────────────
  # A command's trust posture (from its toolkit's #+TRUST), recorded at build time.
  # Drives the isolation tier its calls run at: third-party → :node (a separate
  # BEAM VM); first-party → local subprocess.
  @trust {__MODULE__, :trust}

  @doc "Record a command's trust posture (\"first-party\" | \"third-party\")."
  def set_trust(name, trust) when is_binary(name) and trust in ["first-party", "third-party"] do
    cur = :persistent_term.get(@trust, %{})
    :persistent_term.put(@trust, Map.put(cur, name, trust))
    :ok
  end

  def set_trust(_name, _trust), do: {:error, :invalid_trust}

  @doc "The recorded trust posture for `name` (default \"first-party\")."
  def trust(name), do: Map.get(:persistent_term.get(@trust, %{}), name, "first-party")

  @doc """
  Run a command at the isolation tier its #+TRUST implies (wb-pkh.5): third-party →
  :node (a separate BEAM VM, Workbooks.IsolationNode), with a GRACEFUL fallback to
  the local subprocess if distribution can't be brought up (the command still runs,
  just less isolated — fail-open on availability, never on the work). first-party →
  the normal local path. This is the auto-application of effective_tier; callers
  that want an explicit tier use Fabric.map.
  """
  def run_isolated(name, input, argv \\ []) do
    case Workbooks.Isolation.effective_tier("command", trust(name)) do
      :node ->
        if Workbooks.IsolationNode.available?(),
          do: Workbooks.IsolationNode.run(name, input, argv),
          else: run(name, input, argv)

      _ ->
        run(name, input, argv)
    end
  end

  @doc """
  Register a prebuilt wasm CLI under `name` with an arg mode (:argv | :stdin1).

  SECURITY: rejects empty/nil/malformed names, reserved (built-in) names, and any
  `wasm_path` that does not resolve INSIDE the content-addressed commands store
  (build/commands/). This stops the namespace from being poisoned and stops a
  registration from pointing at arbitrary wasm planted elsewhere on the host.
  Use `register_artifact/3` to register a freshly built artifact (it content-
  addresses into the store first).
  """
  def register(name, wasm_path, mode \\ :argv)

  def register(name, _wasm_path, _mode) when not is_binary(name) or name == "",
    do: {:error, :invalid_name}

  def register(name, wasm_path, mode) do
    cond do
      name in @reserved ->
        {:error, :reserved_name}

      not Regex.match?(@name_re, name) ->
        {:error, :invalid_name}

      not confined_command_path?(wasm_path) ->
        {:error, :path_not_confined}

      true ->
        cur = :persistent_term.get(@dynamic, %{})

        if not Map.has_key?(cur, name) and map_size(cur) >= @max_dynamic do
          {:error, :registry_full}
        else
          :persistent_term.put(@dynamic, Map.put(cur, name, {:wasm, wasm_path, mode}))
          :ok
        end
    end
  end

  @doc """
  Register a prebuilt wasm command WITH default run options — currently `:dirs`,
  host preopens the command always needs (e.g. a language runtime's stdlib dir).
  These merge ahead of caller-supplied dirs at run time. Same guards as register/3.
  """
  def register(name, wasm_path, mode, opts) when is_map(opts) do
    cond do
      not is_binary(name) or name == "" -> {:error, :invalid_name}
      name in @reserved -> {:error, :reserved_name}
      not Regex.match?(@name_re, name) -> {:error, :invalid_name}
      not confined_command_path?(wasm_path) -> {:error, :path_not_confined}
      true ->
        cur = :persistent_term.get(@dynamic, %{})

        if not Map.has_key?(cur, name) and map_size(cur) >= @max_dynamic do
          {:error, :registry_full}
        else
          :persistent_term.put(@dynamic, Map.put(cur, name, {:wasm, wasm_path, mode, opts}))
          :ok
        end
    end
  end

  # A registered path must canonicalize to a file strictly inside the content-
  # addressed commands store. Confines registration to managed build outputs.
  defp confined_command_path?(path) when is_binary(path) do
    base = Workbooks.PackageManager.commands_dir() |> Path.expand()
    abs = Path.expand(path)
    String.starts_with?(abs, base <> "/")
  end

  defp confined_command_path?(_), do: false

  @doc """
  Register a freshly BUILT artifact: content-address it (sha256 → build/commands/
  <sha>.wasm) and register the addressed path under `name`. Idempotent — the same
  source builds to the same bytes → same hash → same path. Returns {:ok, path} so
  callers can report/seed from the stable artifact. Use this for build outputs;
  `register/3` stays for already-content-addressed / prebuilt paths.
  """
  def register_artifact(name, wasm_path, mode \\ :argv) do
    case Workbooks.PackageManager.content_address(wasm_path) do
      {:ok, addressed, _sha} ->
        case register(name, addressed, mode) do
          :ok ->
            persist_manifest(name, addressed, mode)
            {:ok, addressed}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Persistence (boot survives restart) ─────────────────────────────────────
  # Built/registered commands (Lua, duk, …) content-address into build/commands/ but the registry
  # itself is in-memory (persistent_term) — gone on restart. A tiny manifest records (name → addressed
  # path + mode) so `reload_persisted/0` re-registers them at boot WITHOUT rebuilding (the addressed
  # wasm persists). Pallet (Lane A) artifacts re-seed via fetch; this is for the build-from-source set.
  defp manifest_path, do: Path.join(Workbooks.PackageManager.commands_dir(), "registry.json")

  defp persist_manifest(name, addressed, mode) do
    m = read_manifest()
    File.write(manifest_path(), Jason.encode!(Map.put(m, name, %{"path" => addressed, "mode" => to_string(mode)})))
  rescue
    _ -> :ok
  end

  defp read_manifest do
    with {:ok, j} <- File.read(manifest_path()),
         {:ok, m} when is_map(m) <- Jason.decode(j) do
      m
    else
      _ -> %{}
    end
  end

  @doc """
  Re-register the persisted build-from-source commands at boot (Lua/duk/zforth/…) from their cached,
  content-addressed artifacts — NO rebuild, NO fetch. Skips entries whose artifact is gone or whose
  name is reserved/malformed. Returns the count re-registered. Idempotent.
  """
  def reload_persisted do
    Enum.reduce(read_manifest(), 0, fn
      {name, %{"path" => path, "mode" => mode}}, n ->
        mode_atom = if mode == "stdin1", do: :stdin1, else: :argv

        cond do
          name in @reserved -> n
          not Regex.match?(@name_re, name) -> n
          not File.regular?(path) -> n
          register(name, path, mode_atom) == :ok -> n + 1
          true -> n
        end

      _, n ->
        n
    end)
  end

  # Inline languages an agent can self-author a command in. Rust takes crates.io
  # `deps`; the others ignore them. The compiler for each is itself wasm
  # (PackageManager → Compilers), so the build never escapes the sandbox.
  @inline_langs ~w(rust c zig js ts go)

  @doc """
  The inline self-authoring join (wb-rhs.4): build a command from INLINE SOURCE
  an agent wrote, then register it — write → build → content-address → register,
  ENTIRELY in the wasm sandbox. `lang` ∈ #{inspect(@inline_langs)}; `deps` are
  crates.io specs (rust only). Returns {:ok, addressed_path} | {:error, reason}.

  This is what lets an agent author a toolkit for itself mid-session: no native
  toolchain, no host escape (the compiler is itself wasm). SECURITY/TRUST: the
  built command is capped by the Instance's Policy profile exactly like any other
  command — self-authoring builds and runs, but can NEVER exceed the granted
  capability set (an ungranted cap is un-importable → un-callable). Reserved
  built-in names (jq/grep/upper) are refused before any compile.
  """
  def build_and_register_inline(name, lang, source, deps \\ [], mode \\ :argv)

  def build_and_register_inline(name, _lang, _source, _deps, _mode)
      when not is_binary(name) or name == "",
      do: {:error, :invalid_name}

  def build_and_register_inline(name, lang, source, deps, mode) do
    cond do
      name in @reserved ->
        {:error, :reserved_name}

      not Regex.match?(@name_re, name) ->
        {:error, :invalid_name}

      lang not in @inline_langs ->
        {:error, {:unsupported_lang, lang}}

      not is_binary(source) or source == "" ->
        {:error, :empty_source}

      not is_list(deps) ->
        {:error, :invalid_deps}

      true ->
        comp = %{"name" => name, "lang" => lang, "src" => source, "deps" => deps}

        case Workbooks.PackageManager.build(comp) do
          {^name, ^lang, {:ok, wasm, _}} -> register_artifact(name, wasm, mode)
          {_, _, {:error, reason}} -> {:error, {:build_failed, reason}}
          other -> {:error, {:build_failed, other}}
        end
    end
  end

  @doc """
  Build a LOCAL source dir through the in-sandbox compiler lane (PackageManager.build_dir/2 —
  clang.wasm / zig1.wasm / mrustc.wasm, NO native toolchain) and register the resulting wasm as a
  command. `lang` ∈ "c"|"rust"|"zig"|"go". The Lane-B join: a real multi-file C tool (Lua, etc.)
  becomes a live command. Returns {:ok, addressed_path} | {:error, reason}.
  """
  def register_built_dir(name, dir, lang \\ "c", mode \\ :argv, cflags \\ [], include_only \\ []) do
    cond do
      not (is_binary(name) and name != "" and Regex.match?(@name_re, name)) -> {:error, :invalid_name}
      name in @reserved -> {:error, :reserved_name}
      not (is_binary(dir) and File.dir?(dir)) -> {:error, :no_dir}

      true ->
        # cflags (e.g. -DWITH_MAIN) + :include_only (amalgamation .c the driver #includes) only apply to
        # the C lane.
        built =
          if lang == "c" and (cflags != [] or include_only != []),
            do: Workbooks.PackageManager.build_c_dir(Path.expand(dir), cflags, include_only),
            else: Workbooks.PackageManager.build_dir(dir, lang)

        case built do
          {:ok, wasm, _} -> register_artifact(name, wasm, mode)
          {:error, reason} -> {:error, {:build_failed, reason}}
          other -> {:error, {:build_failed, other}}
        end
    end
  end

  @doc """
  Fetch a C tool's SOURCE tarball (.tar.gz), sha-pin, unpack, assemble its source dir, build it
  IN-SANDBOX (clang.wasm) and register the wasm as a command — the prebuilt-less Lane-B path for
  upstream C tools with no shipped WASI binary. opts: `:src_subdir` (dir within the tarball's top
  folder holding the .c/.h, e.g. "src"), `:exclude` (basenames to drop, e.g. a second `main`),
  `:mode`. Building is slow but content-addressed (one-time). Returns {:ok, addressed} | {:error, _}.
  """
  def build_and_register_c_source(name, url, sha256, opts \\ []) do
    cond do
      not (is_binary(name) and name != "" and Regex.match?(@name_re, name)) -> {:error, :invalid_name}
      name in @reserved -> {:error, :reserved_name}
      not (is_binary(url) and String.starts_with?(url, "https://")) -> {:error, :invalid_url}
      true -> do_build_and_register_c_source(name, url, sha256, opts)
    end
  end

  defp do_build_and_register_c_source(name, url, sha256, opts) do
    tmp = Path.join(System.tmp_dir!(), "wbcsrc-#{:erlang.unique_integer([:positive])}.tgz")

    case https_get_to_file(url, tmp) do
      :ok ->
        got = :crypto.hash(:sha256, File.read!(tmp)) |> Base.encode16(case: :lower)

        cond do
          is_binary(sha256) and sha256 != "" and got != String.downcase(String.trim(sha256)) ->
            File.rm(tmp)
            {:error, {:sha_mismatch, [expected: String.downcase(String.trim(sha256)), got: got]}}

          true ->
            unpack = Path.join(System.tmp_dir!(), "wbcsrc-#{got}")
            File.rm_rf!(unpack)
            File.mkdir_p!(unpack)
            # `xf` (no z/J) lets tar auto-detect the compression → handles .tar.gz / .tar.xz / .tar.bz2.
            {tout, tc} = System.cmd("tar", ["xf", tmp, "-C", unpack], stderr_to_stdout: true)
            File.rm(tmp)

            if tc != 0 do
              {:error, {:untar_failed, tout}}
            else
              top =
                case File.ls(unpack) do
                  {:ok, [d]} -> Path.join(unpack, d)
                  _ -> unpack
                end

              builddir = Path.join(System.tmp_dir!(), "wbcbuild-#{got}")
              File.rm_rf!(builddir)
              File.mkdir_p!(builddir)
              exclude = opts[:exclude] || []

              # Source selection: :src_globs (a list of {c,h} globs relative to the tarball top, for
              # tools whose sources span multiple dirs e.g. zForth's src/zforth + src/linux) takes
              # precedence; else :src_subdir (single dir); else the top dir. Files flatten into builddir.
              globs =
                cond do
                  is_list(opts[:src_globs]) -> opts[:src_globs]
                  opts[:src_subdir] -> [Path.join(opts[:src_subdir], "*.{c,h}")]
                  true -> ["*.{c,h}"]
                end

              # Copy preserving each file's path relative to the tarball top, so the build dir mirrors
              # the source tree — tools with relative-parent #includes ("../foo.h", e.g. zstd) resolve.
              for g <- globs, f <- Path.wildcard(Path.join(top, g)), File.regular?(f) do
                unless Path.basename(f) in exclude do
                  dst = Path.join(builddir, Path.relative_to(f, top))
                  File.mkdir_p!(Path.dirname(dst))
                  File.cp!(f, dst)
                end
              end

              # :extra_sources — inject custom {filename, content} files (e.g. a minimal CLI main for a
              # library whose bundled CLI drags in too many extras, or a tool needing a small harness).
              for {fname, content} <- opts[:extra_sources] || [] do
                dst = Path.join(builddir, fname)
                File.mkdir_p!(Path.dirname(dst))
                File.write!(dst, content)
              end

              res = register_built_dir(name, builddir, "c", opts[:mode] || :argv, opts[:cflags] || [], opts[:include_only] || [])
              File.rm_rf!(unpack)
              File.rm_rf!(builddir)
              res
            end
        end

      {:error, reason} ->
        File.rm(tmp)
        {:error, {:fetch_failed, reason}}
    end
  end

  @doc """
  The generic auto-wrap: build an arbitrary upstream Rust CLI crate to
  wasm32-wasip1 and register it as a command — any WASI-clean crate, zero per-CLI
  code. Returns {:ok, wasm_path} | {:error, reason}. (Other languages build via
  PackageManager.build_dir/2 + register/3; this is the cargo-crate convenience.)
  """
  # SECURITY (wb-sec): a crate spec is `<name>` or `<name>@<version>`, both from a
  # conservative charset. This blocks argv OPTION-INJECTION (a leading-dash token
  # like `--git=<attacker-url>` / `--index` / `--path` would otherwise redirect
  # what `cargo install` fetches and builds — chaining into build.rs RCE).
  @crate_re ~r/^[a-zA-Z0-9_][a-zA-Z0-9_.\-]*(@[a-zA-Z0-9_.+\-]+)?$/

  def build_and_register_crate(name, crate, mode \\ :argv)

  def build_and_register_crate(name, _crate, _mode)
      when not is_binary(name) or name == "",
      do: {:error, :invalid_name}

  def build_and_register_crate(name, crate, mode) do
    cond do
      name in @reserved ->
        {:error, :reserved_name}

      not Regex.match?(@name_re, name) ->
        {:error, :invalid_name}

      not is_binary(crate) or not Regex.match?(@crate_re, crate) ->
        {:error, :invalid_crate}

      true ->
        do_build_and_register_crate(name, crate, mode)
    end
  end

  # NATIVE-COMPILE FALLBACK REMOVED (wb-9ja). This used to `cargo install` an
  # arbitrary crate with the NATIVE cargo toolchain — exactly the native execution
  # the no-native-exec canon forbids. There is no honest in-sandbox equivalent for
  # "fetch + build an arbitrary upstream binary crate" yet (cargo's registry
  # resolve + build.rs don't run as a wasmtime guest), so we return an explicit
  # lane-unavailable error rather than silently shell out to native cargo.
  #
  # SUBSTRATE DISTINCTION (read before "fixing" this): wasmtime running a `.wasm`
  # IS the architecture and stays. NATIVE binaries (cargo/rustc/zig/go) are BANNED.
  # Build inline Rust source via build_and_register_inline/5 (lang "rust") instead —
  # it compiles through mrustc.wasm → clang.wasm entirely in-sandbox.
  defp do_build_and_register_crate(_name, _crate, _mode) do
    {:error, {:lane_unavailable, :rust_crate_native_build}}
  end

  # A Go package path (optionally @version). Discrete System.cmd args (no shell), so
  # this guards data shape, not injection.
  @go_pkg_re ~r/^[a-zA-Z0-9._\/\-]+(@[a-zA-Z0-9._+\-]+)?$/

  @doc """
  Build a Go package to wasm (GOOS=wasip1) and register it as a command — e.g. a Go
  INTERPRETER like yaegi, so untrusted .go source runs in the sandbox (Go is
  compiled, so the "runtime" is an interpreter compiled to wasm). Returns
  {:ok, wasm} | {:error, reason}. Caches GO* under a temp root (no host-home writes).
  """
  def build_and_register_go(name, pkg, mode \\ :argv)

  def build_and_register_go(name, _pkg, _mode) when not is_binary(name) or name == "",
    do: {:error, :invalid_name}

  def build_and_register_go(name, pkg, mode) do
    cond do
      name in @reserved -> {:error, :reserved_name}
      not Regex.match?(@name_re, name) -> {:error, :invalid_name}
      not (is_binary(pkg) and Regex.match?(@go_pkg_re, pkg)) -> {:error, :invalid_pkg}
      true -> do_build_and_register_go(name, pkg, mode)
    end
  end

  # NATIVE-COMPILE FALLBACK REMOVED (wb-9ja). This used to drive the NATIVE go
  # toolchain (`go mod`/`go get`/`go build`) to cross-compile a package to wasm.
  # That is native execution of a fetched package's build — banned. Run Go SOURCE
  # in-sandbox via the yaegi interpreter lane (PackageManager build, lang "go")
  # instead; fetching+building an arbitrary upstream Go package natively is gone.
  defp do_build_and_register_go(_name, _pkg, _mode) do
    {:error, {:lane_unavailable, :go_package_native_build}}
  end

  @doc """
  REMOVED (wb-9ja): native-zig compile of a .zig file. The NATIVE `zig build-exe`
  toolchain is banned. Compile Zig SOURCE in-sandbox via the Zig lane
  (PackageManager build/build_dir, lang "zig" → zig1.wasm → clang.wasm). This entry
  point returns lane-unavailable rather than shelling out to native zig.
  """
  def build_and_register_zig(name, _zig_file, _mode \\ :argv) do
    cond do
      not (is_binary(name) and name != "" and Regex.match?(@name_re, name)) -> {:error, :invalid_name}
      name in @reserved -> {:error, :reserved_name}
      true -> {:error, {:lane_unavailable, :zig_native_build}}
    end
  end

  @doc """
  Run a FIRST-PARTY, in-repo build SCRIPT that PROVISIONS a trusted compiler/runtime
  wasm (e.g. `compilers/<lang>/build.sh` building qjs/lua), printing the output wasm
  path as its LAST stdout line; content-address + register it.

  ── SUBSTRATE, NOT a native-compile fallback (wb-9ja) ────────────────────────
  This is TRUSTED PROVISIONING — the same category as PackageManager's `ensure_yaegi`
  / `wasm-tools build.sh`: it builds the trusted TOOLS (the wasm compilers), never
  untrusted USER source. So it runs the script via plain `System.cmd("bash", …)`
  (host provisioning), exactly like those siblings. It is NOT reachable from the
  in-sandbox agent: the only agent-facing caller (`wb toolkit build` with a
  `script:` #+BUILD_SRC from an untrusted toolkit dir) is DISABLED in
  Workbooks.Toolkits. The ban is on the AGENT running native code / the runtime
  native-compiling UNTRUSTED source — not on the host provisioning its own trusted
  compiler wasms from in-repo scripts. Callers must only pass first-party scripts.
  """
  def build_and_register_script(name, script, mode \\ :argv) do
    cond do
      not (is_binary(name) and name != "" and Regex.match?(@name_re, name)) -> {:error, :invalid_name}
      name in @reserved -> {:error, :reserved_name}
      not File.regular?(script) -> {:error, :no_script}
      true ->
        case System.cmd("bash", [script], stderr_to_stdout: true) do
          {out, 0} ->
            wasm = out |> String.split("\n", trim: true) |> List.last() |> to_string() |> String.trim()

            if wasm != "" and File.regular?(wasm),
              do: register_artifact(name, wasm, mode),
              else: {:error, {:no_wasm_from_script, String.slice(to_string(out), max(0, String.length(to_string(out)) - 400)..-1//1)}}

          {err, _} ->
            {:error, {:script_failed, err}}
        end
    end
  end

  @doc """
  Fetch a PREBUILT wasm command from a pinned https URL, verify its sha256,
  content-address it, and register it. This is the "pallet" path for prebuilt
  language runtimes/compilers (qjs, python, …): we do NOT build, so no build.rs /
  no compile-time code runs — a prebuilt is inert bytes until run in the sandbox.
  The ONLY trust gate is the sha PIN: a compromised mirror cannot swap the binary.
  Returns {:ok, addressed_path, sha} | {:error, reason}. A nil `sha256` registers
  whatever is fetched and returns its hash (so an author can pin it); a non-nil
  mismatch is refused. (The artifact still runs capability-gated in the sandbox —
  defense in depth on top of the pin.)
  """
  def fetch_and_register_wasm(name, url, sha256 \\ nil, mode \\ :argv)

  def fetch_and_register_wasm(name, _url, _sha, _mode)
      when not is_binary(name) or name == "",
      do: {:error, :invalid_name}

  def fetch_and_register_wasm(name, url, sha256, mode) do
    cond do
      name in @reserved -> {:error, :reserved_name}
      not Regex.match?(@name_re, name) -> {:error, :invalid_name}
      not (is_binary(url) and String.starts_with?(url, "https://")) -> {:error, :invalid_url}
      true -> do_fetch_and_register_wasm(name, url, sha256, mode)
    end
  end

  # FETCHING a prebuilt .wasm IS the substrate (category A — kept), NOT native
  # compilation. The only thing that changed for wb-9ja: the download no longer
  # shells out to the `curl` BINARY via the (deleted) Sandbox — it uses a pure
  # Erlang/TLS GET (no native process). The fetched prebuilt is inert bytes,
  # sha-pinned before anything trusts it, and only ever RUN in the wasm sandbox.
  defp do_fetch_and_register_wasm(name, url, sha256, mode) do
    tmp = Path.join(System.tmp_dir!(), "wbwasm-#{:erlang.unique_integer([:positive])}.wasm")

    case https_get_to_file(url, tmp) do
      :ok ->
        got = :crypto.hash(:sha256, File.read!(tmp)) |> Base.encode16(case: :lower)

        cond do
          is_binary(sha256) and sha256 != "" and got != String.downcase(String.trim(sha256)) ->
            File.rm(tmp)
            {:error, {:sha_mismatch, [expected: String.downcase(String.trim(sha256)), got: got]}}

          true ->
            result = register_artifact(name, tmp, mode)
            File.rm(tmp)

            case result do
              {:ok, addressed} -> {:ok, addressed, got}
              err -> err
            end
        end

      {:error, reason} ->
        File.rm(tmp)
        {:error, {:fetch_failed, reason}}
    end
  end

  @doc """
  Fetch a PREBUILT runtime shipped as a tar.gz (a wasm + its companion files, e.g.
  a language's standard library), verify sha256, unpack into the content-addressed
  store, and register the inner wasm with a default preopen so the runtime finds
  its resources. `wasm_rel` is the wasm path inside the archive; `preopen` is
  "<subdir>::<guest>" (subdir relative to the unpacked root; "." = root).
  Returns {:ok, wasm_path, sha} | {:error, reason}.
  """
  def fetch_and_register_archive(name, url, sha256, wasm_rel, preopen, mode \\ :argv) do
    cond do
      not (is_binary(name) and name != "" and Regex.match?(@name_re, name)) -> {:error, :invalid_name}
      name in @reserved -> {:error, :reserved_name}
      not (is_binary(url) and String.starts_with?(url, "https://")) -> {:error, :invalid_url}
      not is_binary(wasm_rel) -> {:error, :no_wasm_path}
      true -> do_fetch_and_register_archive(name, url, sha256, wasm_rel, preopen, mode)
    end
  end

  defp do_fetch_and_register_archive(name, url, sha256, wasm_rel, preopen, mode) do
    tmp = Path.join(System.tmp_dir!(), "wbarc-#{:erlang.unique_integer([:positive])}.tgz")

    # Same as the .wasm fetch: pure Erlang/TLS GET (no curl binary), sha-pinned. The
    # tarball is a prebuilt wasm runtime + its companion files — the substrate, not
    # a native compile. (tar unpack below is a host file op on inert, pinned bytes.)
    case https_get_to_file(url, tmp) do
      :ok ->
        got = :crypto.hash(:sha256, File.read!(tmp)) |> Base.encode16(case: :lower)

        cond do
          is_binary(sha256) and sha256 != "" and got != String.downcase(String.trim(sha256)) ->
            File.rm(tmp)
            {:error, {:sha_mismatch, [expected: String.downcase(String.trim(sha256)), got: got]}}

          true ->
            # Unpack into the content-addressed store (build/commands/<sha>.d/) so the
            # inner wasm path is confined there. bsdtar/GNU tar strip leading '/' and
            # refuse '..' traversal by default; the sha pin is the trust gate.
            dir = Path.join(Workbooks.PackageManager.commands_dir(), "#{got}.d")
            File.rm_rf!(dir)
            File.mkdir_p!(dir)
            {tout, tcode} = System.cmd("tar", ["xzf", tmp, "-C", dir], stderr_to_stdout: true)
            File.rm(tmp)

            wasm = Path.join(dir, wasm_rel)

            cond do
              tcode != 0 -> {:error, {:untar_failed, tout}}
              not File.regular?(wasm) -> {:error, {:wasm_not_in_archive, wasm_rel}}
              true ->
                {sub, guest} = parse_preopen(preopen)
                host = Path.expand(Path.join(dir, sub))

                case register(name, wasm, mode, %{dirs: ["#{host}::#{guest}"]}) do
                  :ok -> {:ok, wasm, got}
                  err -> err
                end
            end
        end

      {:error, reason} ->
        File.rm(tmp)
        {:error, {:fetch_failed, reason}}
    end
  end

  @doc """
  Fetch a prebuilt .tar.gz that bundles MANY wasm command modules (e.g. WABT's wat2wasm/wasm2wat/…),
  verify sha256, unpack ONCE into the content-addressed store, and register each `{command_name,
  rel_path}` entry. One download for the whole cluster (vs N for N single-archive calls). The tools
  are self-contained wasm — registered with NO default preopen, so callers pass their own `--dir` for
  file-mode tools. Returns {:ok, registered_names} | {:error, reason}. Same name/url guards as the
  single-archive path; every entry name must be non-reserved and charset-clean.
  """
  def fetch_and_register_archive_many(url, sha256, entries, mode \\ :argv) when is_list(entries) do
    names = Enum.map(entries, fn {n, _} -> n end)

    cond do
      not (is_binary(url) and String.starts_with?(url, "https://")) -> {:error, :invalid_url}
      names == [] -> {:error, :no_entries}
      Enum.any?(names, &(&1 in @reserved)) -> {:error, :reserved_name}
      not Enum.all?(names, &(is_binary(&1) and Regex.match?(@name_re, &1))) -> {:error, :invalid_name}
      not Enum.all?(entries, fn {_, rel} -> is_binary(rel) end) -> {:error, :no_wasm_path}
      true -> do_fetch_and_register_archive_many(url, sha256, entries, mode)
    end
  end

  defp do_fetch_and_register_archive_many(url, sha256, entries, mode) do
    tmp = Path.join(System.tmp_dir!(), "wbarcm-#{:erlang.unique_integer([:positive])}.tgz")

    case https_get_to_file(url, tmp) do
      :ok ->
        got = :crypto.hash(:sha256, File.read!(tmp)) |> Base.encode16(case: :lower)

        cond do
          is_binary(sha256) and sha256 != "" and got != String.downcase(String.trim(sha256)) ->
            File.rm(tmp)
            {:error, {:sha_mismatch, [expected: String.downcase(String.trim(sha256)), got: got]}}

          true ->
            dir = Path.join(Workbooks.PackageManager.commands_dir(), "#{got}.d")
            File.rm_rf!(dir)
            File.mkdir_p!(dir)
            {tout, tcode} = System.cmd("tar", ["xzf", tmp, "-C", dir], stderr_to_stdout: true)
            File.rm(tmp)

            if tcode != 0 do
              {:error, {:untar_failed, tout}}
            else
              results =
                Enum.map(entries, fn {name, rel} ->
                  wasm = Path.join(dir, rel)

                  if File.regular?(wasm),
                    do: {name, register(name, wasm, mode)},
                    else: {name, {:error, {:not_in_archive, rel}}}
                end)

              case Enum.filter(results, fn {_, r} -> r != :ok end) do
                [] -> {:ok, Enum.map(results, &elem(&1, 0))}
                bad -> {:error, {:register_failed, bad}}
              end
            end
        end

      {:error, reason} ->
        File.rm(tmp)
        {:error, {:fetch_failed, reason}}
    end
  end

  @doc """
  Like `fetch_and_register_archive/6` but for a `.zip` — unpacked with Erlang's `:zip` (NO native
  `unzip` binary, honoring the no-native-exec canon). Fetch → sha-pin → unzip into the content-
  addressed store → register the inner `wasm_rel`. Returns {:ok, wasm_path, sha} | {:error, reason}.
  """
  def fetch_and_register_zip(name, url, sha256, wasm_rel, mode \\ :argv) do
    cond do
      not (is_binary(name) and name != "" and Regex.match?(@name_re, name)) -> {:error, :invalid_name}
      name in @reserved -> {:error, :reserved_name}
      not (is_binary(url) and String.starts_with?(url, "https://")) -> {:error, :invalid_url}
      not is_binary(wasm_rel) -> {:error, :no_wasm_path}
      true -> do_fetch_and_register_zip(name, url, sha256, wasm_rel, mode)
    end
  end

  defp do_fetch_and_register_zip(name, url, sha256, wasm_rel, mode) do
    tmp = Path.join(System.tmp_dir!(), "wbzip-#{:erlang.unique_integer([:positive])}.zip")

    case https_get_to_file(url, tmp) do
      :ok ->
        got = :crypto.hash(:sha256, File.read!(tmp)) |> Base.encode16(case: :lower)

        cond do
          is_binary(sha256) and sha256 != "" and got != String.downcase(String.trim(sha256)) ->
            File.rm(tmp)
            {:error, {:sha_mismatch, [expected: String.downcase(String.trim(sha256)), got: got]}}

          true ->
            dir = Path.join(Workbooks.PackageManager.commands_dir(), "#{got}.d")
            File.rm_rf!(dir)
            File.mkdir_p!(dir)

            case :zip.unzip(String.to_charlist(tmp), [{:cwd, String.to_charlist(dir)}]) do
              {:ok, _files} ->
                File.rm(tmp)
                wasm = Path.join(dir, wasm_rel)

                cond do
                  not File.regular?(wasm) ->
                    {:error, {:wasm_not_in_archive, wasm_rel}}

                  true ->
                    case register(name, wasm, mode) do
                      :ok -> {:ok, wasm, got}
                      err -> err
                    end
                end

              {:error, reason} ->
                File.rm(tmp)
                {:error, {:unzip_failed, reason}}
            end
        end

      {:error, reason} ->
        File.rm(tmp)
        {:error, {:fetch_failed, reason}}
    end
  end

  # Pure Erlang/TLS HTTPS GET → file (no curl binary; no native subprocess). Mirrors
  # Workbooks.Npm.https_get / Workbooks.Compilers.http_get (wb-ova: "no curl binary").
  # Verified TLS via the OS trust store; only https URLs reach here (callers gate).
  defp https_get_to_file(url, dest) do
    :inets.start()
    :ssl.start()

    ssl_opts = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)],
      depth: 3
    ]

    http_opts = [ssl: ssl_opts, timeout: 60_000, connect_timeout: 15_000, autoredirect: true]

    case :httpc.request(:get, {String.to_charlist(url), []}, http_opts, body_format: :binary) do
      {:ok, {{_v, 200, _}, _headers, body}} -> File.write(dest, body)
      {:ok, {{_v, code, _}, _headers, _body}} -> {:error, {:http_status, code}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_preopen(nil), do: {".", "/"}

  defp parse_preopen(spec) do
    case String.split(String.trim(spec), "::", parts: 2) do
      [sub, guest] -> {sub, guest}
      [sub] -> {sub, "/"}
    end
  end

  @doc "Run a registered command with stdin `input` (no argv) → {:ok, out} | {:error, reason}."
  def run(name, input), do: run(name, input, [])

  @doc """
  Run a registered command with stdin `input` AND `argv` (a list) → {:ok, out} |
  {:error, reason}. `dirs` are host paths preopened into the guest (WASI --dir) for
  file-mode CLIs. How argv reaches the command is per its registered arg mode:
  :argv passes real wasmtime argv; :stdin1 folds argv into the first stdin line.
  """
  def run(name, input, argv, dirs \\ [], ropts \\ []) when is_list(argv) do
    case run_status(name, input, argv, dirs, ropts) do
      {:ok, out, _status} -> {:ok, out}
      other -> other
    end
  end

  @doc """
  Like run/5 but also returns the command's exit status: {:ok, out, status} |
  {:error, reason}. Workbooks.Shell uses this for &&/|| control flow.
  """
  def run_status(name, input, argv, dirs \\ [], ropts \\ []) when is_list(argv) do
    case registry()[name] do
      nil -> {:error, {:unknown_command, name}}
      spec -> run_builtin(spec, input, argv, dirs, ropts)
    end
  end

  defp run_builtin({:wasm, path, mode}, input, argv, dirs, ropts) do
    # SECURITY (wb-sec): content-addressed artifacts in build/commands/<sha>.wasm
    # are verified at RUN time, not just at register time — closing the TOCTOU
    # where the bytes at the path are swapped after registration. The filename IS
    # the sha256 of the trusted bytes; we re-hash on load and refuse a mismatch.
    case verify_artifact(path) do
      :ok ->
        {stdin, args} = apply_argmode(mode, input, argv)

        case Workbooks.PackageManager.run(path, stdin, args, dirs, [{:with_status, true} | ropts]) do
          {:error, _} = err -> err
          {out, status} -> {:ok, maybe_trim(out, ropts), status}
        end

      {:error, _} = err ->
        err
    end
  end

  # A runtime registered with default preopens (e.g. its stdlib): merge them ahead
  # of the caller's dirs so it always finds its resources. The spec may also carry
  # default run opts (:run_opts, e.g. a compiler's higher fuel/timeout).
  defp run_builtin({:wasm, path, mode, opts}, input, argv, dirs, ropts) do
    # opts[:argv] is a FROZEN argv prefix (e.g. a python-tool's ["-c", script]); opts[:dirs] are
    # default preopens (e.g. a runtime's stdlib, or a frozen site-packages dir). Both merge ahead of
    # the caller's. This makes a "base interpreter + frozen script + mounted package" a first-class
    # command (Lane D: pure-Python tools riding CPython) with no new spec kind.
    run_builtin(
      {:wasm, path, mode},
      input,
      Map.get(opts, :argv, []) ++ argv,
      Map.get(opts, :dirs, []) ++ dirs,
      Keyword.merge(Map.get(opts, :run_opts, []), ropts)
    )
  end

  defp run_builtin({:src, lang, src, mode}, input, argv, dirs, ropts) do
    case Workbooks.PackageManager.build(%{"name" => "cmd", "lang" => lang, "src" => src}) do
      {_, _, {:ok, wasm, _}} ->
        {stdin, args} = apply_argmode(mode, input, argv)

        case Workbooks.PackageManager.run(wasm, stdin, args, dirs, [{:with_status, true} | ropts]) do
          {:error, _} = err -> err
          {out, status} -> {:ok, maybe_trim(out, ropts), status}
        end

      {_, _, err} ->
        {:error, err}
    end
  end

  # Command output is trimmed for standalone/human use by default, but pipelines
  # need byte-exact bytes (a stripped trailing "\n" makes `wc -l` undercount).
  # Workbooks.Shell passes trim: false for inter-stage piping. (wb-9ja)
  defp maybe_trim(out, ropts), do: if(Keyword.get(ropts, :trim, true), do: String.trim(out), else: out)

  # Re-verify a content-addressed artifact's bytes against the sha256 in its
  # filename. Built-in prebuilt artifacts (jq.wasm/grep.wasm) and source-built
  # outputs are not content-addressed by filename → no hash to check (skip). Only
  # build/commands/<64-hex>.wasm carries a verifiable hash.
  defp verify_artifact(path) when is_binary(path) do
    base = Path.basename(path, ".wasm")

    if Regex.match?(~r/^[0-9a-f]{64}$/, base) do
      case File.read(path) do
        {:ok, bytes} ->
          actual = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
          if actual == base, do: :ok, else: {:error, {:artifact_integrity, path}}

        {:error, reason} ->
          {:error, {:read_artifact, path, reason}}
      end
    else
      :ok
    end
  end

  # :argv → args go to wasmtime as argv. :stdin1 → args become the first stdin
  # line (legacy), so the wasm sees no argv. Empty argv is a no-op either way.
  defp apply_argmode(_mode, input, []), do: {input, []}
  defp apply_argmode(:argv, input, argv), do: {input, argv}
  defp apply_argmode(:stdin1, input, argv), do: {Enum.join(argv, " ") <> "\n" <> input, []}
end
