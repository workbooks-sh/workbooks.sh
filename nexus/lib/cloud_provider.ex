defmodule Nexus.CloudProvider do
  @moduledoc """
  The compute-provider contract behind Workbooks Cloud (wb-jr1py.1) — exactly the verbs
  `Nexus.Cloud` calls, extracted from the Fly broker (`Nexus.Cloud.Fly`, the reference
  implementor) so a second provider is a module + a registry entry, not a rewrite.

  A provider vends a tenant an isolated deployment (`provision/2` — Fly: app+volume+machine;
  an edge provider: project+namespace), reports/steers its lifecycle, rolls its image, and
  tears it down. `app`/`unit` are the provider's own two-level handle (Fly: app name +
  machine id) — opaque to callers, persisted in the registry row by `Nexus.Cloud`.

  Selection is CONFIG (`deploy provider="fly"` → `Nexus.Config.cloud_provider/0`), resolved
  through a registry map so tests/operators can extend it (`config :nexus, :cloud_providers`).
  Unknown name ⇒ `{:error, {:unknown_provider, name}}` — fail closed, never a silent default.
  THE LINE: the contract + registry are neutral runtime; provider modules carry the vendor.

  Every callback keeps the broker result contract: `{:ok, _} | {:error, _} | {:skip, _}`
  (`{:skip, _}` = provider not configured — feature dark, never an error).
  """

  @type result :: {:ok, term} | {:error, term} | {:skip, term}

  @callback configured?() :: boolean
  @callback provision(tenant :: String.t(), opts :: keyword) :: result
  @callback status(app :: String.t(), unit :: String.t(), opts :: keyword) :: result
  @callback start(app :: String.t(), unit :: String.t(), opts :: keyword) :: result
  @callback stop(app :: String.t(), unit :: String.t(), opts :: keyword) :: result
  @callback suspend(app :: String.t(), unit :: String.t(), opts :: keyword) :: result
  @callback update_image(app :: String.t(), unit :: String.t(), image :: String.t(), opts :: keyword) :: result
  @callback teardown(app :: String.t(), unit :: String.t(), opts :: keyword) :: result
  @callback app_name(tenant :: String.t()) :: String.t()

  @builtin %{"fly" => Nexus.Cloud.Fly}

  @doc """
  Resolve the configured provider module: `deploy provider="…"` → registry lookup.
  `{:ok, module} | {:error, {:unknown_provider, name}}`.
  """
  def resolve do
    name = Nexus.Config.cloud_provider() || "fly"

    case Map.fetch(registry(), name) do
      {:ok, mod} -> {:ok, mod}
      :error -> {:error, {:unknown_provider, name}}
    end
  end

  @doc "The provider registry (builtin + `config :nexus, :cloud_providers` extensions)."
  def registry, do: Map.merge(@builtin, Application.get_env(:nexus, :cloud_providers, %{}))
end
