defmodule Nexus.Paths do
  @moduledoc """
  THE single source of truth for where the nexus stores things on disk — and for the **durable
  boundary**.

  `data_dir/0` (WB_DATA) is the deploy root: it holds the shipped workbook tree and is **EPHEMERAL**
  (the image rootfs, wiped on every machine churn / suspend→resume onto a new host). The persistent
  volume is mounted at `durable_dir/0` (`<data_dir>/.nexus`). **Everything that must survive a
  restart/redeploy/machine-replacement MUST resolve under `durable_dir/0`**; anything else under
  `data_dir/0` is ephemeral by definition.

  This module exists because "durable" had drifted away from the mount in a dozen scattered path
  computations — the class of bug that wiped the accounts DB. There is now exactly ONE place that
  decides what durable means; every store, cache, repo, and the entrypoint resolve through here.
  """

  @doc "Deploy root (WB_DATA). EPHEMERAL. Machine identity (a mount path), not a tunable knob — so the env read is the legitimate kind, like PORT/NEXUS_TENANT."
  def data_dir, do: System.get_env("WB_DATA") || File.cwd!()

  @doc "Persistent-volume root (`<data_dir>/.nexus`). ALL durable state lives under here."
  def durable_dir, do: Path.join(data_dir(), ".nexus")

  @doc """
  The ONE SQLite database — accounts, orgs, control-plane records, encrypted org secrets, API tokens,
  swarm sessions, and (in prod) resource rows. On the volume + Litestream-replicated. `:cp_sqlite_path`
  overrides it (tests / a deliberate cloud adapter).
  """
  def db_path, do: Application.get_env(:nexus, :cp_sqlite_path) || Path.join(durable_dir(), "nexus.db")

  @doc "Git bare repos — the durable source of truth for pushed workspaces (and drafts)."
  def repos_root, do: Path.join(durable_dir(), "repos")

  @doc "A workspace's working checkout. EPHEMERAL — re-derived from its bare repo on boot (Nexus.Server.rehydrate_checkouts)."
  def work_dir(name), do: Path.join(data_dir(), name)

  @doc "Cold cache + workspace backups. Durable on the volume by default (or off-box when `cache-cold` is an s3:// URI)."
  def cold_dir, do: Path.join(durable_dir(), "cache")

  @doc "Compiled wasm artifacts. EPHEMERAL by design — rebuilt by recompiling, so they must NOT consume the volume."
  def component_cache_dir, do: Path.join(data_dir(), "build/components")
end
