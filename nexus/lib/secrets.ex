defmodule Nexus.Secrets do
  @moduledoc """
  The ONE seam for reading deploy-time **secrets** (API keys, tokens). The runtime
  reads every secret through here — never scattered `System.get_env` — so there is a
  single audited path and one place that knows which secrets exist.

  ## Resolution order

  A secret resolves **store-first, env-fallback**:

    1. The encrypted, org-scoped `Nexus.ControlPlane.Env` store (AES-256-GCM at rest,
       Doppler-like) — the `nexus`-scoped secrets an operator adds/edits in the dashboard.
       This is the editable source of truth, so a value set in the UI actually takes
       effect at runtime.
    2. The process env — genuine deploy injection: machine identity / mount paths
       (`WB_DATA`, `NEXUS_TENANT`, `PORT`), bootstrap secrets (`WB_ENV_MASTER_KEY`), and
       anything a deploy injects that was never moved into the store.

  Store lookups are **fail-safe**: no control plane, no master key, or no tenant → we fall
  straight through to env (never an error, never a crash on a hot path).

  ## The standard (config vs secret vs identity)

    * **Tunable config** (concurrency, cache, search provider …) → the `.work`
      `deploy do … end` block, read via `Nexus.Config`. Not a secret, not env.
    * **Secrets** (API keys, tokens) → declared by name, resolved here (store, then env).
      The value is **never** written into source, a `.work` file, or config.
    * **Machine identity / mount paths** (`WB_DATA`, `NEXUS_TENANT`, `PORT`) → genuine
      deploy injection, read directly where needed (not secrets, not config).

  `WB_ENV_MASTER_KEY` is the root key that unlocks the store, so it is read directly by
  `Nexus.ControlPlane.Env` from the env, not through this seam (it can't come from the
  store it decrypts) — and there is no `nexus`-scoped record for it, so a `get/1` for it
  simply falls through to env.
  """

  @doc "The secret's value, or `nil` if unset/blank. Store-first, then process env."
  def get(name) when is_binary(name), do: store_value(name) || env_value(name)

  defp env_value(name) do
    case System.get_env(name) do
      nil -> nil
      "" -> nil
      v -> v
    end
  end

  # Nexus-scoped secret from the encrypted store, when the store is reachable. Any failure
  # (control plane off, no master key, no tenant, decrypt error) → nil, so env is used.
  defp store_value(name) do
    if Nexus.ControlPlane.enabled?() do
      case Nexus.ControlPlane.Env.value(secrets_org(), name) do
        {:ok, v} when is_binary(v) and v != "" -> v
        _ -> nil
      end
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  # The org that owns this nexus (one nexus per org). Context-free: the tenant injected at provision.
  defp secrets_org, do: System.get_env("NEXUS_TENANT") || Nexus.Store.default_tenant()

  @doc "The secret's value or a default when unset/blank."
  def get(name, default), do: get(name) || default

  @doc "`{:ok, value}` or `{:error, {:missing_secret, name}}`."
  def fetch(name) when is_binary(name) do
    case get(name) do
      nil -> {:error, {:missing_secret, name}}
      v -> {:ok, v}
    end
  end

  @doc "True when the secret is present and non-blank."
  def has?(name) when is_binary(name), do: get(name) != nil
end
