defmodule Workbooks.Tenant do
  @moduledoc """
  wb-an2v: the single source of truth for the broker PRINCIPAL (tenant) a dock runs under. The principal is
  the isolation boundary for the stateful brokers — StorageBroker partitions KV by it, SecretBroker namespaces
  signing keys by it, and RateLimiter/Revocation key on it.

  THE BUG THIS CLOSES: the docks used to default a missing `:tenant` to the SHARED CONSTANT `"default"`. Every
  un-tenanted guest then read/wrote the SAME `"default"` KV partition and signed in the SAME secret namespace —
  a cross-tenant isolation break (a guest could read another's persisted data). The whole command lane
  (CommandRegistry → PackageManager → JsDock) carried no tenant, so this was the PRODUCTION path.

  THE RULE: an explicit `:tenant` is used verbatim (the caller pinned a real, host-supplied identity). A
  MISSING tenant falls back to a UNIQUE EPHEMERAL id — never a shared constant — so two un-tenanted runs get
  DISJOINT namespaces (fail-ISOLATED): they can't see each other's data, and they can't reach a real tenant's
  secrets. Persistence/secrets require passing an explicit tenant; the default is a private, throwaway scope.
  """

  @doc """
  Resolve the broker principal from dock opts. `Keyword.get(opts, :tenant)` if the caller pinned one (any
  non-empty binary), else a fresh unique ephemeral id. NEVER returns a shared constant.
  """
  def resolve(opts) when is_list(opts) do
    case Keyword.get(opts, :tenant) do
      t when is_binary(t) and t != "" -> t
      _ -> ephemeral()
    end
  end

  @doc "A fresh, unique, unguessable ephemeral tenant id (its own isolated KV/secret namespace)."
  def ephemeral do
    "eph-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  end
end
