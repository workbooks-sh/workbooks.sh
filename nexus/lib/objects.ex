defmodule Nexus.Objects do
  @moduledoc """
  The workbook-facing **object store** seam — what a workbook's `r2`/S3 data method resolves to, the
  blob counterpart of `Nexus.Store` (rows). One bucket per workbook: `put/get/head/list/delete` over
  opaque byte blobs keyed by string paths.

  Routing mirrors the data store: with production secrets injected (`Nexus.S3.configured?/0`) it
  speaks to the real R2/S3 bucket from config; otherwise it writes to the workbook's faked local
  bucket — the `~/.workbooks/dev/s3/<uuid>/` folder (`:s3_local_dir`, installed on serve by
  `Nexus.Workbooks`). Same calls work in dev and prod; dev blobs live only under `~/.workbooks/dev`.

  `list/1` + `delete/1` are first-class on the local store; on the minimal cloud client they aren't
  supported (it does immutable get/put/head only) and return `{:error, :not_supported}`.
  """

  @doc "Store `body` (bytes) at `key`. → `:ok | {:error, reason}`."
  def put(key, body) do
    if cloud?(), do: Nexus.S3.put(loc(), key, body), else: Nexus.S3.Local.put(local_dir(), key, body)
  end

  @doc "Fetch `key`. → `{:ok, body} | {:error, :not_found | reason}`."
  def get(key) do
    if cloud?(), do: Nexus.S3.get(loc(), key), else: Nexus.S3.Local.get(local_dir(), key)
  end

  @doc "Existence check. → `:ok | :not_found | {:error, reason}`."
  def head(key) do
    if cloud?(), do: Nexus.S3.head(loc(), key), else: Nexus.S3.Local.head(local_dir(), key)
  end

  @doc "List object keys under `prefix`. Local-only; cloud → `{:error, :not_supported}`."
  def list(prefix \\ "") do
    if cloud?(), do: {:error, :not_supported}, else: Nexus.S3.Local.list(local_dir(), prefix)
  end

  @doc "Delete `key`. Local-only; cloud → `{:error, :not_supported}`."
  def delete(key) do
    if cloud?(), do: {:error, :not_supported}, else: Nexus.S3.Local.delete(local_dir(), key)
  end

  # Cloud only when creds AND a dedicated blob bucket are configured. We do NOT fall back to BUCKET_NAME
  # (that's the Litestream DB bucket) — co-mingling user blobs with the DB replica is a blast-radius
  # hazard. No blob bucket ⇒ the DURABLE local store on the volume.
  defp cloud?, do: Nexus.S3.configured?() and loc().bucket not in [nil, ""]

  # Local bucket — per-workbook dir set on serve, else a DURABLE default UNDER THE VOLUME (Nexus.Paths),
  # so uploaded blobs survive a restart even when no object-store bucket is configured. (Was
  # ~/.workbooks/dev/s3 — ephemeral container home — which silently lost blobs on churn.)
  defp local_dir do
    Application.get_env(:nexus, :s3_local_dir) || Path.join([Nexus.Paths.durable_dir(), "blobs", "default"])
  end

  # The production object-store location — resolved through the ONE audited seam (Nexus.Secrets), with
  # the standard AWS_* fallbacks, exactly like Nexus.S3/Litestream. `WB_S3_PREFIX` is the per-tenant
  # prefix the provisioner injects (`tenants/<org>/`), so blobs are tenant-isolated within the bucket.
  defp loc do
    %{
      endpoint: Nexus.Secrets.get("WB_S3_ENDPOINT") || Nexus.Secrets.get("AWS_ENDPOINT_URL_S3"),
      bucket: Nexus.Secrets.get("WB_S3_BUCKET"),
      prefix: Nexus.Secrets.get("WB_S3_PREFIX") || "",
      region: Nexus.Secrets.get("WB_S3_REGION") || Nexus.Secrets.get("AWS_REGION") || "auto"
    }
  end
end
