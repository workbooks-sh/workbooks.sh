defmodule Workbooks.Storage do
  @moduledoc """
  Tenant-scoped BLOB storage — the BYOD seam. The runtime writes workbook bytes
  (`.wbundle`s, published artifacts, sealed blobs) through THIS interface; a
  deploy picks the backend with `WB_STORAGE` and implements it with an adapter.
  Add a provider = one module + one config line, never a runtime fork (the same
  pattern as the Browse provider slot).

  Tenant-scoped BY CONSTRUCTION: `tenant` is the first argument of every call, so
  isolation lives ABOVE the backend — swapping a Fly volume for R2 can't widen
  access. Auth (BetterAuth→Guardian) decides WHO the tenant is; this just stores
  their bytes under that scope. See docs/DEPLOY-KIT-STORAGE.org.
  """
  @callback put(tenant :: String.t(), key :: String.t(), bytes :: binary) :: :ok | {:error, term}
  @callback get(tenant :: String.t(), key :: String.t()) :: {:ok, binary} | :error
  @callback list(tenant :: String.t(), prefix :: String.t()) :: [String.t()]
  @callback delete(tenant :: String.t(), key :: String.t()) :: :ok

  @doc "The configured adapter — `WB_STORAGE=local|s3` (default local)."
  def adapter do
    case System.get_env("WB_STORAGE", "local") do
      "s3" -> Workbooks.Storage.S3
      "r2" -> Workbooks.Storage.S3
      _ -> Workbooks.Storage.Local
    end
  end

  def put(tenant, key, bytes), do: adapter().put(to_string(tenant), safe_key(key), bytes)
  def get(tenant, key), do: adapter().get(to_string(tenant), safe_key(key))
  def list(tenant, prefix \\ ""), do: adapter().list(to_string(tenant), prefix)
  def delete(tenant, key), do: adapter().delete(to_string(tenant), safe_key(key))

  # Keys are relative paths under the tenant scope — never absolute, never `..`,
  # so a key can't escape its tenant prefix on a filesystem backend.
  defp safe_key(key) do
    key |> to_string() |> Path.split() |> Enum.reject(&(&1 in ["", ".", "..", "/"])) |> Path.join()
  end
end
