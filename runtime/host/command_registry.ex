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
  # use — the in-WASM shell's command vocabulary (wb-9ja). Source in
  # compilers/wbox/wbox.c, embedded here so it ships with the release.
  @wbox_c_path Path.expand("../compilers/wbox/wbox.c", __DIR__)
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
          :ok -> {:ok, addressed}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
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

  defp do_build_and_register_crate(name, crate, mode) do
    # The temp root is derived from a now-validated crate token, but still expand
    # to be safe and to avoid surprises from a future relaxed charset.
    root = Path.expand(Path.join(System.tmp_dir!(), "wbcmd-#{crate}"))

    # SECURITY (wb-sec): `--` terminates option parsing so `crate` can never be
    # read as a flag (kills cargo option-injection). The compile runs FS-confined
    # via Workbooks.Sandbox.run_net. RESIDUAL RISK: `cargo install` MUST reach the
    # registry to fetch the crate, so the network cannot be denied around the
    # fetch — a fetched crate's build.rs still runs with network during install.
    # This is the documented inherent trust boundary of installing an arbitrary
    # published crate (callers must allowlist/review crate names). The offline,
    # network-DENIED path is build_dir/2 for a local, already-vendored source tree.
    # Options FIRST, then `--`, then the crate spec — so `crate` can never be read
    # as an option (cargo parses everything after `--` as positional crate specs).
    case Workbooks.Sandbox.run_net(
           ["cargo", "install", "--target", "wasm32-wasip1", "--root", root, "--no-track", "--", crate],
           env: cargo_env()
         ) do
      {_, 0} ->
        case Path.wildcard(Path.join([root, "bin", "*.wasm"])) do
          [wasm | _] ->
            # Content-address the build output so the registry points at a stable
            # build/commands/<sha>.wasm, not cargo's transient --root temp dir.
            register_artifact(name, wasm, mode)

          [] ->
            {:error, :no_wasm}
        end

      {err, _} ->
        {:error, err}
    end
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

  defp do_build_and_register_go(name, pkg, mode) do
    root = Path.join(System.tmp_dir!(), "wbgo-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(root)
    out = Path.join(root, "out.wasm")
    base = pkg |> String.split("@") |> hd()
    env = go_env(root)

    with {_, 0} <- Workbooks.Sandbox.run_net(["go", "mod", "init", "wbgo"], cd: root, env: env),
         {_, 0} <- Workbooks.Sandbox.run_net(["go", "get", pkg], cd: root, env: env),
         {_, 0} <- Workbooks.Sandbox.run_net(["go", "build", "-o", out, base], cd: root, env: env) do
      if File.regular?(out), do: register_artifact(name, out, mode), else: {:error, :no_wasm}
    else
      {err, _} -> {:error, err}
    end
  end

  defp go_env(root) do
    [
      {"GOOS", "wasip1"},
      {"GOARCH", "wasm"},
      {"GOPATH", Path.join(root, "gp")},
      {"GOCACHE", Path.join(root, "gc")},
      {"GOMODCACHE", Path.join(root, "gm")},
      {"PATH", "/opt/homebrew/bin:/usr/local/go/bin:#{System.get_env("PATH")}"}
    ]
  end

  @doc """
  Compile a Zig SOURCE file to a wasm32-wasi command (native zig) and register it.
  Zig has no sandboxed interpreter (compiler-in-wasm is the LLVM mountain) — it is a
  compile-to-wasm AUTHORING language: write a tool in Zig, get a sandboxed command.
  Offline build (no deps fetched); zig cache pinned to a temp dir.
  """
  def build_and_register_zig(name, zig_file, mode \\ :argv) do
    cond do
      not (is_binary(name) and name != "" and Regex.match?(@name_re, name)) -> {:error, :invalid_name}
      name in @reserved -> {:error, :reserved_name}
      not File.regular?(zig_file) -> {:error, :no_source}
      true ->
        out = Path.join(System.tmp_dir!(), "wbzig-#{:erlang.unique_integer([:positive])}.wasm")
        cache = Path.join(System.tmp_dir!(), "wbzigc-#{:erlang.unique_integer([:positive])}")

        env = [
          {"PATH", "/opt/homebrew/bin:#{System.get_env("PATH")}"},
          {"ZIG_GLOBAL_CACHE_DIR", cache},
          {"ZIG_LOCAL_CACHE_DIR", cache}
        ]

        case Workbooks.Sandbox.run(
               ["zig", "build-exe", zig_file, "-target", "wasm32-wasi", "-O", "ReleaseSmall", "-femit-bin=#{out}"],
               env: env
             ) do
          {_, 0} -> if File.regular?(out), do: register_artifact(name, out, mode), else: {:error, :no_wasm}
          {err, _} -> {:error, err}
        end
    end
  end

  @doc """
  Run a committed build SCRIPT that compiles a language from source (e.g. Lua via
  wasi-sdk) and prints the output wasm path as its LAST stdout line; content-address
  + register it. For build-from-source runtimes with no upstream prebuilt. The
  script is first-party (lives in the toolkit dir), runs network-permitted (it may
  fetch a pinned source tarball + toolchain).
  """
  def build_and_register_script(name, script, mode \\ :argv) do
    cond do
      not (is_binary(name) and name != "" and Regex.match?(@name_re, name)) -> {:error, :invalid_name}
      name in @reserved -> {:error, :reserved_name}
      not File.regular?(script) -> {:error, :no_script}
      true ->
        case Workbooks.Sandbox.run_net(["bash", script]) do
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

  defp do_fetch_and_register_wasm(name, url, sha256, mode) do
    tmp = Path.join(System.tmp_dir!(), "wbwasm-#{:erlang.unique_integer([:positive])}.wasm")

    # -f fail on HTTP error, --proto =https forbids downgrade/file:, `--` ends opts
    # so the URL can never be read as a flag. Fetch needs network; the prebuilt is
    # then sha-verified before anything trusts it.
    case Workbooks.Sandbox.run_net(["curl", "-fsSL", "--proto", "=https", "-o", tmp, "--", url]) do
      {_, 0} ->
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

      {err, _} ->
        File.rm(tmp)
        {:error, {:fetch_failed, err}}
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

    case Workbooks.Sandbox.run_net(["curl", "-fsSL", "--proto", "=https", "-o", tmp, "--", url]) do
      {_, 0} ->
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

      {err, _} ->
        File.rm(tmp)
        {:error, {:fetch_failed, err}}
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
    run_builtin(
      {:wasm, path, mode},
      input,
      argv,
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

  defp cargo_env, do: [{"PATH", "#{Path.expand("~/.cargo/bin")}:#{System.get_env("PATH")}"}]

  # :argv → args go to wasmtime as argv. :stdin1 → args become the first stdin
  # line (legacy), so the wasm sees no argv. Empty argv is a no-op either way.
  defp apply_argmode(_mode, input, []), do: {input, []}
  defp apply_argmode(:argv, input, argv), do: {input, argv}
  defp apply_argmode(:stdin1, input, argv), do: {Enum.join(argv, " ") <> "\n" <> input, []}
end
