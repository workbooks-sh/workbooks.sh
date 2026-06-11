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

  # Each entry: name · url · sha256 (pinned) · wasm_rel (path inside the .tar.gz) · preopen
  # ("<subdir>::<guest>" or "." = package root → "/") · mode (:argv | :stdin1).
  @catalog [
    %{
      name: "coreutils",
      url: "https://github.com/uutils/coreutils/releases/download/0.9.0/coreutils-0.9.0-wasm32-wasip1.tar.gz",
      sha: "e5efa8a1c10bd0ac09eb780d46aff6d8a4ea0be07d41f4dd9a102b266c6eb69f",
      wasm_rel: "coreutils-0.9.0-wasm32-wasip1/coreutils.wasm",
      preopen: ".",
      mode: :argv
    },
    %{
      name: "sqlite3",
      url: "https://cdn.wasmer.io/packages/_/sqlite/sqlite-0.2.2.tar.gz",
      sha: "93d4c1f1b3625c311b431076fe071fa1a111472520fbcffd934fafee5e7cc2ed",
      wasm_rel: "build/sqlite.wasm",
      preopen: ".",
      mode: :argv
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

  def seed_one(%{name: n, url: u, sha: s, wasm_rel: w, preopen: p, mode: m}) do
    case CommandRegistry.fetch_and_register_archive(n, u, s, w, p, m) do
      {:ok, _wasm, _sha} -> :ok
      other -> other
    end
  end
end
