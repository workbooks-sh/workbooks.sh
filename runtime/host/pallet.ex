defmodule Workbooks.Pallet do
  @moduledoc """
  Lane A — the prebuilt-WASI command pallet (feasibility-matrix campaign).

  A catalog of sha-PINNED, validated standalone WASI artifacts (real CLIs/runtimes already
  compiled to `wasm32-wasi`) wired into the sandbox through the EXISTING
  `CommandRegistry.fetch_and_register_archive/6` mechanism — pure-Erlang TLS fetch → sha-pin →
  content-address into `build/commands/` → register → run under wasmtime. There is NO per-tool
  engine code here: the lane IS the registry mechanism; each tool is just DATA (name, url, sha,
  the wasm path inside the archive, a default `--dir` preopen, and an arg mode).

  Every entry was PROVED by actually running it under wasmtime (the smoke that verified each is in
  `runtime/.campaign/promote-live.json`). `seed/0` registers them; `seed_one/1` does a single tool.

  Adding a tool = fetch it once, capture its sha256 + the inner `.wasm` path, append a map here.
  The whole `wire-up` cluster lights up through this one path (lanes, not 129 implementations).
  """

  alias Workbooks.CommandRegistry

  # Each entry: name · kind (:wasm single artifact | :archive .tar.gz) · url · sha256 (pinned) ·
  # mode (:argv | :stdin1). :archive entries also carry wasm_rel (path inside the tarball) + preopen
  # ("<subdir>::<guest>" or "." = package root → "/"). Single :wasm entries register via
  # fetch_and_register_wasm; :archive via fetch_and_register_archive.
  @catalog [
    # ── Language runtimes (single-file WASI .wasm) ──────────────────────────────
    %{
      name: "python",
      kind: :wasm,
      url: "https://github.com/vmware-labs/webassembly-language-runtimes/releases/download/python/3.12.0%2B20231211-040d5a6/python-3.12.0.wasm",
      sha: "e5dc5a398b07b54ea8fdb503bf68fb583d533f10ec3f930963e02b9505f7a763",
      mode: :argv
    },
    %{
      name: "ruby",
      kind: :wasm,
      url: "https://github.com/vmware-labs/webassembly-language-runtimes/releases/download/ruby/3.2.2%2B20230714-11be424/ruby-3.2.2-slim.wasm",
      sha: "de598f394e398763d2b147e3e51a6eeadf048128598ac4a3f992a97204c192b0",
      mode: :argv
    },
    %{
      name: "wasm3",
      kind: :wasm,
      url: "https://github.com/wasm3/wasm3/releases/download/v0.5.0/wasm3-wasi.wasm",
      sha: "8427e2f97a14e8c36708fa2c9864f73d1f499305449b5def2cc1b96bfc54a783",
      mode: :argv
    },
    # ── Tools shipped as .tar.gz (wasm + companions) ────────────────────────────
    %{
      name: "coreutils",
      kind: :archive,
      url: "https://github.com/uutils/coreutils/releases/download/0.9.0/coreutils-0.9.0-wasm32-wasip1.tar.gz",
      sha: "e5efa8a1c10bd0ac09eb780d46aff6d8a4ea0be07d41f4dd9a102b266c6eb69f",
      wasm_rel: "coreutils-0.9.0-wasm32-wasip1/coreutils.wasm",
      preopen: ".",
      mode: :argv
    },
    %{
      name: "sqlite3",
      kind: :archive,
      url: "https://cdn.wasmer.io/packages/_/sqlite/sqlite-0.2.2.tar.gz",
      sha: "93d4c1f1b3625c311b431076fe071fa1a111472520fbcffd934fafee5e7cc2ed",
      wasm_rel: "build/sqlite.wasm",
      preopen: ".",
      mode: :argv
    },
    # ── Multi-tool archive (one tarball → many commands, one download) ──────────
    %{
      name: "wabt",
      kind: :archive_many,
      url: "https://github.com/WebAssembly/wabt/releases/download/1.0.41/wabt-1.0.41-wasi.tar.gz",
      sha: "b1f09bde4a7f407d8d2b43b6076004dedf64780cbfcf7cce19207a11ade06f9c",
      mode: :argv,
      entries: [
        {"wat2wasm", "wabt-1.0.41/bin/wat2wasm"},
        {"wasm2wat", "wabt-1.0.41/bin/wasm2wat"},
        {"wasm-validate", "wabt-1.0.41/bin/wasm-validate"},
        {"wasm-decompile", "wabt-1.0.41/bin/wasm-decompile"},
        {"wasm-interp", "wabt-1.0.41/bin/wasm-interp"},
        {"wasm-objdump", "wabt-1.0.41/bin/wasm-objdump"},
        {"wasm-stats", "wabt-1.0.41/bin/wasm-stats"},
        {"wasm-strip", "wabt-1.0.41/bin/wasm-strip"},
        {"wasm2c", "wabt-1.0.41/bin/wasm2c"},
        {"wast2json", "wabt-1.0.41/bin/wast2json"},
        {"wat-desugar", "wabt-1.0.41/bin/wat-desugar"},
        {"spectest-interp", "wabt-1.0.41/bin/spectest-interp"}
      ]
    }
  ]

  @doc "The validated pallet catalog (data — each entry sha-pinned + proven under wasmtime)."
  def catalog, do: @catalog

  @doc "Catalog entry names."
  def names, do: Enum.map(@catalog, & &1.name)

  @doc """
  Register every pallet entry (fetch + sha-pin + content-address + register). Returns
  `%{name => :ok | {:error, reason}}`. Idempotent at the registry level — re-seeding replaces the
  binding in place (hot-swap). Network: fetches each artifact once into the content-addressed store.
  """
  def seed, do: Map.new(@catalog, fn e -> {e.name, seed_one(e)} end)

  @doc "Register a single catalog entry by name (or the entry map) → :ok | {:error, reason}."
  def seed_one(name) when is_binary(name) do
    case Enum.find(@catalog, &(&1.name == name)) do
      nil -> {:error, :unknown_pallet_entry}
      e -> seed_one(e)
    end
  end

  def seed_one(%{kind: :wasm, name: n, url: u, sha: s, mode: m}) do
    case CommandRegistry.fetch_and_register_wasm(n, u, s, m) do
      {:ok, _addressed, _sha} -> :ok
      other -> other
    end
  end

  def seed_one(%{kind: :archive, name: n, url: u, sha: s, wasm_rel: w, preopen: p, mode: m}) do
    case CommandRegistry.fetch_and_register_archive(n, u, s, w, p, m) do
      {:ok, _wasm, _sha} -> :ok
      other -> other
    end
  end

  def seed_one(%{kind: :archive_many, url: u, sha: s, entries: es, mode: m}) do
    case CommandRegistry.fetch_and_register_archive_many(u, s, es, m) do
      {:ok, _names} -> :ok
      other -> other
    end
  end
end
