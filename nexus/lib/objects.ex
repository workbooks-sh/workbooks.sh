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

  defp cloud?, do: Nexus.S3.configured?()

  # The faked local bucket — installed per workbook on serve; falls back to a default under the home.
  defp local_dir do
    Application.get_env(:nexus, :s3_local_dir) || Path.join([Nexus.Workbooks.home(), "dev", "s3", "default"])
  end

  # The production R2/S3 location (endpoint/bucket/prefix/region) from config — the workbook's prefix
  # scopes its objects within the shared bucket.
  defp loc do
    %{
      endpoint: System.get_env("WB_S3_ENDPOINT"),
      bucket: System.get_env("WB_S3_BUCKET"),
      prefix: Application.get_env(:nexus, :s3_prefix, ""),
      region: System.get_env("WB_S3_REGION") || "auto"
    }
  end
end
