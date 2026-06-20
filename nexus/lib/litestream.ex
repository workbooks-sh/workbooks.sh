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

  @doc """
  The durable SQLite database path — under a hidden `.nexus/` subdir of the mounted volume so it can
  never be served by the static file tier (which lives at the same volume root for a tenant).
  """
  def db_path, do: Path.join([Config.data_dir(), ".nexus", "nexus.db"])

  @doc "The conventional litestream config path inside the deployed image."
  def config_path, do: @config_path

  # Read a value under our canonical `WB_S3_*` name, falling back to the standard S3 env names that
  # `fly storage create` (Tigris) and the AWS SDKs set — so provisioning via Fly "just works" with no
  # manual secret mapping, while `WB_S3_*` stays the explicit override. All via Nexus.Secrets.
  defp s3(canonical, standard), do: Secrets.get(canonical) || Secrets.get(standard)

  defp bucket, do: s3("WB_S3_BUCKET", "BUCKET_NAME")
  defp access_key_id, do: s3("WB_S3_ACCESS_KEY_ID", "AWS_ACCESS_KEY_ID")
  defp secret_access_key, do: s3("WB_S3_SECRET_ACCESS_KEY", "AWS_SECRET_ACCESS_KEY")
  defp endpoint, do: s3("WB_S3_ENDPOINT", "AWS_ENDPOINT_URL_S3")
  defp region, do: s3("WB_S3_REGION", "AWS_REGION") || "auto"

  @doc "True when an object-store replica is configured (bucket + access key present, either scheme)."
  def enabled?, do: bucket() != nil and access_key_id() != nil

  @doc "The access-key pair litestream reads from its env (LITESTREAM_*). Empty map when disabled."
  def credential_env do
    if enabled?(),
      do: %{"LITESTREAM_ACCESS_KEY_ID" => access_key_id(), "LITESTREAM_SECRET_ACCESS_KEY" => secret_access_key()},
      else: %{}
  end

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
        bucket: bucket(),
        path: [prefix, "litestream", "nexus.db"] |> Path.join() |> String.trim_leading("/"),
        endpoint: endpoint(),
        region: region()
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
