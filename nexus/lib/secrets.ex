defmodule Nexus.Secrets do
  @moduledoc """
  The ONE seam for reading deploy-time **secrets** (API keys, tokens). The runtime
  reads every secret through here — never scattered `System.get_env` — so there is a
  single audited path and one place that knows which secrets exist.

  ## The standard

  Three distinct things, three homes — never confuse them:

    * **Tunable config** (concurrency, cache, search provider …) → the `.work`
      `deploy do … end` block, read via `Nexus.Config`. Not a secret, not env.
    * **Secrets** (API keys, tokens) → declared by name, value resolved here from the
      process env at run time. The value is **never** written into source, a `.work`
      file, or config. How it gets INTO the env is deploy injection:
        - **cloud**: from the encrypted, org-scoped `Nexus.ControlPlane.Env`
          (AES-256-GCM at rest, Doppler-like) — injected per machine at deploy.
        - **local / CLI**: from a gitignored local store (`work secret`), injected
          for the run.
    * **Machine identity / mount paths** (`WB_DATA`, `NEXUS_TENANT`, `PORT`) → genuine
      deploy injection, read directly where needed (not secrets, not config).

  `WB_ENV_MASTER_KEY` is the root key that unlocks the cloud store, so it is read
  directly by `Nexus.ControlPlane.Env`, not through this seam (it can't come from the
  store it decrypts).
  """

  @doc "The secret's value, or `nil` if unset/blank."
  def get(name) when is_binary(name) do
    case System.get_env(name) do
      nil -> nil
      "" -> nil
      v -> v
    end
  end

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
