defmodule Nexus.Litestream do
  @moduledoc """
  Litestream durability for the nexus's local SQLite store — continuous WAL replication to an
  egress-free object store (R2 / any S3-compatible), plus restore-on-boot.

  **Why this shape.** One nexus = one machine = one BEAM writer, so the database is **local SQLite on
  the mounted volume** — single-writer is exactly SQLite's sweet spot (microsecond reads, no network
  hop). Litestream streams the WAL off-box continuously, so a wiped or replaced machine restores to
  the last shipped frame. The volume is the primary durable copy; the object store is the off-machine
  DR copy. Relational/extension workloads opt into Postgres separately (a workbook's `postgres`
  data declaration) — this is the standardized default everyone gets for free.

  **Generic mechanism (THE LINE).** No Workbooks-specific values live here. Any operator who injects
  their own `WB_S3_*` secrets gets replication; with none, the nexus runs SQLite-on-volume with no
  replica (still durable within the machine's volume). The litestream config is **generated from the
  injected secrets** (via `Nexus.Secrets`) — never an authored config surface — and the object-store
  keys are passed to litestream through `LITESTREAM_*` env, never written into the config file.
  """
  alias Nexus.{Config, Secrets}

  @config_path "/etc/litestream.yml"

  @doc "The durable SQLite database path on the mounted volume (`WB_DATA`)."
  def db_path, do: Path.join(Config.data_dir(), "nexus.db")

  @doc "The conventional litestream config path inside the deployed image."
  def config_path, do: @config_path

  @doc "True when an object-store replica is configured (S3/R2 secrets injected)."
  def enabled?, do: Secrets.has?("WB_S3_BUCKET") and Secrets.has?("WB_S3_ACCESS_KEY_ID")

  @doc """
  The S3/R2 replica spec built from injected secrets, or `nil` when unconfigured. Object path is
  namespaced under the deployment's `WB_S3_PREFIX` (if any) + `litestream/` so it never collides
  with the object store's data objects.
  """
  def replica do
    if enabled?() do
      prefix = Secrets.get("WB_S3_PREFIX", "")

      %{
        type: "s3",
        bucket: Secrets.get("WB_S3_BUCKET"),
        path: [prefix, "litestream", "nexus.db"] |> Path.join() |> String.trim_leading("/"),
        endpoint: Secrets.get("WB_S3_ENDPOINT"),
        region: Secrets.get("WB_S3_REGION", "auto")
      }
    end
  end

  @doc """
  Litestream config YAML for `replica` (default: the S3/R2 replica from secrets) and `db` (default:
  the volume DB path). Keys are intentionally omitted — litestream reads them from `LITESTREAM_*`
  env so no secret is ever written to disk. The `file` replica form is used by the validation
  harness to exercise the full cycle offline.
  """
  def config_yaml(replica \\ nil, db \\ nil) do
    rep = replica || replica()
    path = db || db_path()

    body =
      [
        "dbs:",
        "  - path: #{path}",
        "    replicas:",
        "      - type: #{rep.type}"
      ] ++ replica_lines(rep)

    Enum.join(body, "\n") <> "\n"
  end

  defp replica_lines(%{type: "s3"} = r) do
    [
      "        bucket: #{r.bucket}",
      "        path: #{r.path}",
      "        endpoint: #{r.endpoint}",
      "        region: #{r.region}"
    ]
  end

  defp replica_lines(%{type: "file", path: p}), do: ["        path: #{p}"]

  @doc """
  Generate + write the litestream config to `path` (default `/etc/litestream.yml`). Called by the
  boot entrypoint before it execs `litestream replicate`. Returns `:ok` / `{:error, reason}`;
  `{:error, :no_replica}` when no object-store replica is configured (the entrypoint then runs the
  app un-replicated).
  """
  def write_config(path \\ @config_path) do
    case replica() do
      nil -> {:error, :no_replica}
      _ -> File.write(path, config_yaml())
    end
  end
end
