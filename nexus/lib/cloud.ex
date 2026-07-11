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
  alias Nexus.Cloud.{Composio, Channels}

  @kind :cloud_tenant

  # Compute provider (wb-jr1py.1): resolved per call from `deploy provider="…"` via the
  # `Nexus.CloudProvider` registry (default fly). Unknown name fails closed before any broker call.
  defp with_provider(fun) do
    case Nexus.CloudProvider.resolve() do
      {:ok, mod} -> fun.(mod)
      {:error, _} = err -> err
    end
  end

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
        with_provider(fn provider ->
          case provider.provision(tenant, opts) do
            {:ok, m} ->
              # The bearer lives ONLY on the machine config — strip it before persisting (mirrors
              # Nexus.Provisioner: the registry stores routing/identity, never a live secret).
              attrs =
                m
                |> Map.take([:fly_app, :fly_machine, :volume, :region, :image, :state])
                |> Map.merge(edge_front(m, opts))

              {:ok, rec} = CP.put(tenant, @kind, tenant, attrs)
              emit("cloud.provisioned", tenant, %{fly_app: rec[:fly_app]})
              {:ok, rec}

            other ->
              other
          end
        end)
    end
  end

  # CF edge in front of the tenant machine (wb-jr1py.6): when the deploy declares
  # `cloud-tenant-domain` and the Cloudflare DNS seam is configured, the tenant gets a PROXIED
  # hostname — `<fly-app>.<domain>` CNAME→`<fly-app>.fly.dev` at Cloudflare (the edge absorbs the
  # byte egress + caches per response headers) — and the hostname is registered on the Fly app so
  # the origin routes + certs it. Best-effort by design: any skip/error leaves the tenant on the
  # raw fly.dev URL and never fails the provision. Test seams: opts[:cf_http]/[:cf_token]/[:cf_zone]
  # (Cloudflare) ride the same injection convention as opts[:http] (Fly).
  defp edge_front(m, opts) do
    cf = [token: opts[:cf_token], http: opts[:cf_http], zone: opts[:cf_zone]] |> Enum.reject(fn {_, v} -> is_nil(v) end)

    with domain when is_binary(domain) and domain != "" <- Nexus.Config.cloud_tenant_domain(),
         hostname = "#{m[:fly_app]}.#{domain}",
         record = %{"type" => "CNAME", "name" => hostname, "content" => "#{m[:fly_app]}.fly.dev", "proxied" => true},
         {:ok, _} <- Nexus.Cloudflare.upsert_dns_record(record, cf) do
      _ = Nexus.Fly.add_certificate(m[:fly_app], hostname, Keyword.take(opts, [:http, :token]))
      emit("cloud.edge_fronted", m[:tenant], %{hostname: hostname})
      %{hostname: hostname}
    else
      _ -> %{}
    end
  end

  @doc "The tenant's stored record. `{:ok, record} | {:error, :not_found}`."
  def get(tenant), do: CP.get(tenant, @kind, tenant)

  @doc "Live machine status (registry row + the live machine map). Ownership is the tenant scope."
  def status(tenant, opts \\ []) do
    with_provider(fn provider ->
      with_machine(tenant, opts, fn m -> merge_machine(m, provider.status(m[:fly_app], m[:fly_machine], opts)) end)
    end)
  end

  def start(tenant, opts \\ []), do: lifecycle(tenant, opts, :start, "running")
  def stop(tenant, opts \\ []), do: lifecycle(tenant, opts, :stop, "stopped")
  def suspend(tenant, opts \\ []), do: lifecycle(tenant, opts, :suspend, "suspended")

  @doc "Roll the tenant's machine to a new image and record it. `{:ok, record} | {:error,_} | {:skip,_}`."
  def update_image(tenant, image, opts \\ []) when is_binary(image) do
    with_provider(fn provider ->
      with_machine(tenant, opts, fn m ->
        case provider.update_image(m[:fly_app], m[:fly_machine], image, opts) do
          {:ok, _} -> CP.update(tenant, @kind, tenant, %{image: image})
          other -> other
        end
      end)
    end)
  end

  @doc "Destroy the tenant's machine + app, then the registry row. `{:ok, :torn_down} | {:error,_} | {:skip,_}`."
  def teardown(tenant, opts \\ []) do
    with_provider(fn provider ->
      with_machine(tenant, opts, fn m ->
        case provider.teardown(m[:fly_app], m[:fly_machine], opts) do
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

  defp lifecycle(tenant, opts, verb, new_state) when verb in [:start, :stop, :suspend] do
    with_provider(fn provider ->
      with_machine(tenant, opts, fn m ->
        case apply(provider, verb, [m[:fly_app], m[:fly_machine], opts]) do
          {:ok, _} -> CP.update(tenant, @kind, tenant, %{state: new_state})
          other -> other
        end
      end)
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
