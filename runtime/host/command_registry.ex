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
    "grep" => {:wasm, "build/commands/grep.wasm", :stdin1}
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

  @doc "Run a registered command with stdin `input` (no argv) → {:ok, out} | {:error, reason}."
  def run(name, input), do: run(name, input, [])

  @doc """
  Run a registered command with stdin `input` AND `argv` (a list) → {:ok, out} |
  {:error, reason}. `dirs` are host paths preopened into the guest (WASI --dir) for
  file-mode CLIs. How argv reaches the command is per its registered arg mode:
  :argv passes real wasmtime argv; :stdin1 folds argv into the first stdin line.
  """
  def run(name, input, argv, dirs \\ []) when is_list(argv) do
    case registry()[name] do
      nil -> {:error, {:unknown_command, name}}
      spec -> run_builtin(spec, input, argv, dirs)
    end
  end

  defp run_builtin({:wasm, path, mode}, input, argv, dirs) do
    # SECURITY (wb-sec): content-addressed artifacts in build/commands/<sha>.wasm
    # are verified at RUN time, not just at register time — closing the TOCTOU
    # where the bytes at the path are swapped after registration. The filename IS
    # the sha256 of the trusted bytes; we re-hash on load and refuse a mismatch.
    case verify_artifact(path) do
      :ok ->
        {stdin, args} = apply_argmode(mode, input, argv)

        case Workbooks.PackageManager.run(path, stdin, args, dirs) do
          {:error, _} = err -> err
          out -> {:ok, String.trim(out)}
        end

      {:error, _} = err ->
        err
    end
  end

  defp run_builtin({:src, lang, src, mode}, input, argv, dirs) do
    case Workbooks.PackageManager.build(%{"name" => "cmd", "lang" => lang, "src" => src}) do
      {_, _, {:ok, wasm, _}} ->
        {stdin, args} = apply_argmode(mode, input, argv)

        case Workbooks.PackageManager.run(wasm, stdin, args, dirs) do
          {:error, _} = err -> err
          out -> {:ok, String.trim(out)}
        end

      {_, _, err} ->
        {:error, err}
    end
  end

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
