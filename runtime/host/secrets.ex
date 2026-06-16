defmodule Workbooks.Secrets do
  @moduledoc """
  Runtime secret store (wb-2s09). The desktop forwards the user's API keys to
  POST /internal/secrets/refresh; the engine's host-side loaders (llm.ex,
  image_gen.ex) resolve creds through here.

  Why this exists: bare `System.put_env/2` from the web handler did NOT reach the
  agent's `System.get_env/1` — on the containerized runtime the forwarded
  OPENROUTER_API_KEY read back EMPTY every time (the agent run resolves env in a
  context that doesn't observe the web request's put_env). So we persist the
  value two reliable, boundary-proof ways:

    * `:persistent_term` — node-global, in-memory, instant.
    * a small JSON file on the local filesystem — survives any process/node
      boundary on this host (a peer node shares the FS) and a restart.

  `get/1` resolves persistent_term → file → process env (so a deploy that sets
  the var the classic way still works) → default.
  """

  def path, do: Path.join(System.tmp_dir!(), "wb-runtime-secrets.json")

  @doc "Store a forwarded secret durably (persistent_term + file)."
  def put(key, value) when is_binary(key) and is_binary(value) do
    :persistent_term.put({__MODULE__, key}, value)
    System.put_env(key, value)
    map = Map.put(load_file(), key, value)
    _ = File.write(path(), Jason.encode!(map))
    :ok
  end

  @doc "Resolve a secret: persistent_term → file → process env → default."
  def get(key, default \\ nil) when is_binary(key) do
    case :persistent_term.get({__MODULE__, key}, :none) do
      :none -> Map.get(load_file(), key) || System.get_env(key) || default
      v -> v
    end
  end

  # ── per-tenant scoping (acp-cloud-enable gap #4) ─────────────────────────────
  # The bare key store above is NODE-GLOBAL (one platform secret, billed/authed as the platform). For a
  # hosted multi-tenant posture a tenant's OWN forwarded secret must NOT collide with the platform's or another
  # tenant's. These overloads namespace the persistent_term + file key by `{tenant, key}`, so a per-tenant
  # value is isolated. The canonical per-tenant LLM key resolution is `Workbooks.Vars.host_secret/2`
  # (Llm.resolve_key uses it); this is the durable forwarded-secret analogue for the same tenant dimension.

  @doc "Store a tenant-scoped secret durably (namespaced persistent_term + file)."
  def put(tenant, key, value)
      when is_binary(tenant) and is_binary(key) and is_binary(value) do
    :persistent_term.put({__MODULE__, tenant, key}, value)
    map = Map.put(load_file(), scoped(tenant, key), value)
    _ = File.write(path(), Jason.encode!(map))
    :ok
  end

  @doc """
  Resolve a tenant-scoped secret, falling back to the node-global one. Tenant value wins so a tenant that
  forwarded its OWN key bills/authenticates as itself; an unconfigured tenant falls back to the platform key.
  """
  def get(tenant, key, default)
      when is_binary(tenant) and is_binary(key) do
    case :persistent_term.get({__MODULE__, tenant, key}, :none) do
      :none -> Map.get(load_file(), scoped(tenant, key)) || get(key, default)
      v -> v
    end
  end

  defp scoped(tenant, key), do: tenant <> "\x00" <> key

  defp load_file do
    case File.read(path()) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{} = m} -> m
          _ -> %{}
        end

      _ ->
        %{}
    end
  end
end
