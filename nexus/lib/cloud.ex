defmodule Nexus.Cloud do
  @moduledoc """
  **Workbooks Cloud** — the SUPER-SIMPLE control plane that vends each customer their own Fly machine
  running the autopoet BEAM app, plus a whitelabeled Composio tools layer. The stripped-down twin of the
  dogfood cloud manager (`Nexus.Provisioner` + `Nexus.Platform` + `Nexus.ControlPlane`): same seams,
  narrower surface.

  ## Shape (thin broker, desktop-first)
  The cloud UI isn't ready, so the **autopoet desktop** calls this control plane's HTTP API
  (`Nexus.Cloud.Api`, mounted at `/api/cloud`). The brokers hold the high-value tokens (`FLY_ORG_TOKEN`,
  `COMPOSIO_API_KEY`) server-side — the desktop never sees them. This module is the orchestration +
  persistence layer between the API and the two brokers.

  ## What it borrows (nothing reinvented)
    * `Nexus.Cloud.Fly` → composes the audited `Nexus.Fly` REST client for provision/lifecycle.
    * `Nexus.Cloud.Composio` → the whitelabel tools broker (mirrors `Nexus.Google`'s no-op-safe seam).
    * `Nexus.ControlPlane` → the durable, Litestream-replicated, **org-scoped** SQLite registry. The
      tenant record is keyed `{tenant, :cloud_tenant, tenant}` — the tenant id IS the isolation scope, so
      a tenant can only ever read its OWN machine/composio map (cross-tenant reads are structurally
      impossible, exactly like the fleet control plane).
    * `Nexus.Secrets` → the one secret seam (both tokens resolve through it, store-first then env).
    * `Nexus.Events` → emits `cloud.*` lifecycle events onto the bus (best-effort, never load-bearing).

  ## No-op-safe
  Every verb degrades to `{:skip, reason}` when its token is absent (`Nexus.Cloud.Fly.configured?/0`,
  `Nexus.Cloud.Composio.configured?/0`), so this compiles and tests green with zero secrets.

  ## Not built yet (where it slots)
  The Workbooks-Cloud account/OAuth provider is NOT here — `tenant` is supplied by whatever auth the API
  runs under (`conn.assigns[:tenant]`, the same seam `Nexus.Platform` uses). When the cloud account system
  lands, it sets that assign; nothing else changes.
  """
  alias Nexus.ControlPlane, as: CP
  alias Nexus.Cloud.{Fly, Composio, Channels}

  @kind :cloud_tenant

  # ── machine lifecycle ────────────────────────────────────────────────────────────────────────────

  @doc """
  Provision (or return the existing) machine for `tenant`. One machine per tenant — a second call returns
  the existing record rather than fanning out machines. Persists the routing/identity map (never the
  bearer). `{:ok, record} | {:error, reason} | {:skip, reason}`.
  """
  def provision(tenant, opts \\ []) do
    case get(tenant) do
      {:ok, existing} ->
        {:ok, existing}

      {:error, :not_found} ->
        case Fly.provision(tenant, opts) do
          {:ok, m} ->
            # The bearer lives ONLY on the Fly machine config — strip it before persisting (mirrors
            # Nexus.Provisioner: the registry stores routing/identity, never a live secret).
            attrs = Map.take(m, [:fly_app, :fly_machine, :volume, :region, :image, :state])
            {:ok, rec} = CP.put(tenant, @kind, tenant, attrs)
            emit("cloud.provisioned", tenant, %{fly_app: rec[:fly_app]})
            {:ok, rec}

          other ->
            other
        end
    end
  end

  @doc "The tenant's stored record. `{:ok, record} | {:error, :not_found}`."
  def get(tenant), do: CP.get(tenant, @kind, tenant)

  @doc "Live machine status (registry row + the live Fly machine map). Ownership is the tenant scope."
  def status(tenant, opts \\ []),
    do: with_machine(tenant, opts, fn m -> merge_machine(m, Fly.status(m[:fly_app], m[:fly_machine], opts)) end)

  def start(tenant, opts \\ []), do: lifecycle(tenant, opts, &Fly.start/3, "running")
  def stop(tenant, opts \\ []), do: lifecycle(tenant, opts, &Fly.stop/3, "stopped")
  def suspend(tenant, opts \\ []), do: lifecycle(tenant, opts, &Fly.suspend/3, "suspended")

  @doc "Roll the tenant's machine to a new image and record it. `{:ok, record} | {:error,_} | {:skip,_}`."
  def update_image(tenant, image, opts \\ []) when is_binary(image) do
    with_machine(tenant, opts, fn m ->
      case Fly.update_image(m[:fly_app], m[:fly_machine], image, opts) do
        {:ok, _} -> CP.update(tenant, @kind, tenant, %{image: image})
        other -> other
      end
    end)
  end

  @doc "Destroy the tenant's machine + app, then the registry row. `{:ok, :torn_down} | {:error,_} | {:skip,_}`."
  def teardown(tenant, opts \\ []) do
    with_machine(tenant, opts, fn m ->
      case Fly.teardown(m[:fly_app], m[:fly_machine], opts) do
        {:ok, _} = ok ->
          CP.delete(tenant, @kind, tenant)
          emit("cloud.torn_down", tenant, %{fly_app: m[:fly_app]})
          ok

        {:skip, _} = skip ->
          skip

        {:error, _} = err ->
          err
      end
    end)
  end

  # ── whitelabeled tools (Composio) ────────────────────────────────────────────────────────────────
  # The tenant id IS the Composio user_id — one stable identity, isolated connected accounts.

  @doc "Toolkits available to connect. `{:ok, list} | {:error,_} | {:skip,_}`."
  def list_tools(opts \\ []), do: Composio.list_toolkits(opts)

  @doc "Register OUR whitelabel OAuth client for `toolkit`. `creds` = `%{client_id, client_secret, redirect_uri}`."
  def create_tool_auth_config(toolkit, creds, opts \\ []), do: Composio.create_auth_config(toolkit, creds, opts)

  @doc """
  Start a tool connection for `tenant` against a whitelabel auth config (`ac_…`). Returns the record with
  a `redirect_url` to open for consent. `{:ok, connection} | {:error,_} | {:skip,_}`.
  """
  def connect_tool(tenant, auth_config_id, opts \\ []), do: Composio.connect(tenant, auth_config_id, opts)

  @doc "Poll a tool connection. `{:ok, %{status}} | {:error,_} | {:skip,_}`."
  def tool_status(connection_id, opts \\ []), do: Composio.connection_status(connection_id, opts)

  @doc "The tenant's per-user MCP URL for `toolkits`. `{:ok, url} | {:error,_} | {:skip,_}`."
  def tool_mcp_url(tenant, toolkits, opts \\ []) when is_list(toolkits), do: Composio.mcp_url(tenant, toolkits, opts)

  @doc "Registered whitelabel auth configs (which toolkits are connectable)."
  def list_tool_auth_configs(opts \\ []), do: Composio.list_auth_configs(opts)

  @doc "The tenant's connected tool accounts."
  def list_tool_connections(tenant, opts \\ []), do: Composio.list_connections(tenant, opts)

  @doc "Disconnect one connected account."
  def disconnect_tool(connection_id, opts \\ []), do: Composio.disconnect(connection_id, opts)

  # ── channels (phone: Telnyx number provisioning + toll-free verification) ────────────────────────
  @doc "Search purchasable toll-free numbers. `{:ok, list} | {:skip,_} | {:error,_}`."
  def channel_numbers(opts \\ []), do: Channels.available_numbers(opts)

  @doc "Provision a number for `tenant` (order + messaging profile + registry). `{:ok, record} | …`."
  def provision_number(tenant, number, opts \\ []), do: Channels.provision(tenant, number, opts)

  @doc "The tenant's provisioned numbers."
  def list_numbers(tenant), do: Channels.list(tenant)

  @doc "Release (deregister) a number."
  def release_number(tenant, number), do: Channels.release(tenant, number)

  @doc "Submit a toll-free verification request for the tenant's number."
  def submit_tf_verification(tenant, body, opts \\ []), do: Channels.submit_verification(tenant, body, opts)

  @doc "Fetch a toll-free verification's status."
  def tf_verification_status(id, opts \\ []), do: Channels.verification_status(id, opts)

  # ── internals ──────────────────────────────────────────────────────────────────────────────────
  defp with_machine(tenant, _opts, fun) do
    case get(tenant) do
      {:ok, m} -> fun.(m)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp lifecycle(tenant, opts, fly_fun, new_state) do
    with_machine(tenant, opts, fn m ->
      case fly_fun.(m[:fly_app], m[:fly_machine], opts) do
        {:ok, _} -> CP.update(tenant, @kind, tenant, %{state: new_state})
        other -> other
      end
    end)
  end

  defp merge_machine(rec, {:ok, machine}), do: {:ok, %{record: rec, machine: machine}}
  defp merge_machine(_rec, other), do: other

  defp emit(kind, tenant, extra) do
    Nexus.Events.emit(Map.merge(%{kind: kind, tenant: tenant}, extra), tenant: tenant)
  rescue
    _ -> :noop
  catch
    _, _ -> :noop
  end
end
