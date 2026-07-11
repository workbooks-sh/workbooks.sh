defmodule Nexus.Cloud.Fly do
  @moduledoc """
  Workbooks-Cloud's Fly **broker** — the stripped-down twin of `Nexus.Provisioner`. It vends each
  customer their OWN Fly app + volume + machine running the autopoet image, using the Fly-blessed
  one-app-per-customer model (app-scoped secrets ⇒ tenant isolation, a unique 6PN network per app).

  ## What it borrows (do not reinvent)
    * `Nexus.Fly` — the audited Fly Machines REST client (TLS-pinned, token-never-logged, `opts[:http]`
      injectable). This broker only *composes* it; the raw HTTP/JSON lives there.
    * `Nexus.Secrets` — the single secret seam. The org token is `Nexus.Secrets.get("FLY_ORG_TOKEN")`,
      never `System.get_env`. It is passed to `Nexus.Fly` as `opts[:token]`, so the token stays on the
      broker side (the desktop never sees it) yet reuses `Nexus.Fly`'s token handling.

  ## No-op-safe (like `Nexus.Google.configured?/0`)
  With no `FLY_ORG_TOKEN` and no injected transport, every verb returns `{:skip, :fly_not_configured}` —
  the feature is dark until the token lands, so the app compiles and tests green with zero secrets.

  ## Injection for tests
  `opts[:http]` (a `(method,url,headers,body) -> {:ok,{status,body}}|{:error,_}` transport) and
  `opts[:token]` flow straight through to `Nexus.Fly`, so the whole provision path is exercised with no
  network. Presence of either (or a configured secret) is what flips the no-op gate on.

  This module is PURE Fly — no persistence. `Nexus.Cloud` layers the registry row + Composio on top.

  Reference implementor of `Nexus.CloudProvider` (wb-jr1py.1): the behaviour is exactly this
  broker's verb surface, so conformance is by construction — zero behavior change.
  """
  @behaviour Nexus.CloudProvider

  alias Nexus.Fly

  @default_region "sjc"
  @default_memory_mb 512
  @default_volume_gb 10
  # the deployed runtime image serves on this port (matched by the health check). Config-overridable.
  @internal_port 8080

  # The OCI image the provisioner deploys per tenant. THE LINE: the open runtime carries NO product
  # image — default to the neutral published runtime (Nexus.Config.runtime_image, itself deploy-config
  # driven, e.g. ghcr.io/workbooks-sh/runtime:latest); an operator overrides per-call (opts[:image]) or
  # via deploy config. (Was hardcoded to registry.fly.io/autopoet:v1 — a product binding in the runtime.)
  defp default_image, do: Nexus.Config.runtime_image()

  @doc """
  Is the broker configured for REAL provisioning? Requires BOTH the org token AND
  a dedicated org slug — the latter is the fail-safe that keeps customer machines
  out of the production/personal org. Missing either → dark (mirrors `Nexus.Google`).
  """
  @impl true
  def configured?,
    do: Nexus.Secrets.has?("FLY_ORG_TOKEN") and org_slug([]) not in [nil, "", "personal"]

  @doc """
  Provision a customer's machine: create app (dedicated 6PN) → volume → machine → wait `started`.
  Returns `{:ok, %{tenant, fly_app, fly_machine, volume, region, image, state, bearer}}`,
  `{:error, reason}`, or `{:skip, :fly_not_configured}`.

  On a mid-flight failure the app is best-effort deleted (it cascades the volume/machine that may hold
  live secrets) so no half-built orphan is left behind.
  """
  @impl true
  def provision(tenant, opts \\ []) do
    cond do
      blank?(tenant) -> {:error, :no_tenant}
      not valid_tenant?(tenant) -> {:error, :invalid_tenant}
      not ready?(opts) -> {:skip, :fly_not_configured}
      true -> do_provision(tenant, opts)
    end
  end

  defp do_provision(tenant, opts) do
    app = app_name(tenant)
    region = opts[:region] || @default_region
    image = opts[:image] || Nexus.Secrets.get("WB_RUNTIME_IMAGE") || default_image()
    bearer = rand_secret()
    fo = fly_opts(opts)

    volume_attrs = %{
      "name" => "data",
      "size_gb" => opts[:volume_gb] || @default_volume_gb,
      "encrypted" => true,
      "region" => region
    }

    with {:ok, _app} <- Fly.create_app(app, org_slug(opts), [network: app] ++ fo),
         {:ok, vol} <- Fly.create_volume(app, volume_attrs, fo),
         volume_id = id_of(vol),
         config = machine_config(tenant, image, region, volume_id, bearer, opts),
         {:ok, machine} <- Fly.create_machine(app, config, fo) do
      machine_id = id_of(machine)
      _ = Fly.wait_machine(app, machine_id, "started", fo)

      {:ok,
       %{
         tenant: tenant,
         fly_app: app,
         fly_machine: machine_id,
         volume: volume_id,
         region: region,
         image: image,
         state: "started",
         bearer: bearer
       }}
    else
      {:skip, _} = skip -> skip
      {:error, reason} ->
        _ = Fly.delete_app(app, fly_opts(opts))
        {:error, reason}
    end
  end

  @doc "Live machine status. `{:ok, machine_map} | {:error,_} | {:skip,_}`."
  @impl true
  def status(app, machine_id, opts \\ []), do: guarded(opts, fn -> Fly.get_machine(app, machine_id, fly_opts(opts)) end)

  @impl true
  def start(app, machine_id, opts \\ []), do: guarded(opts, fn -> Fly.start_machine(app, machine_id, fly_opts(opts)) end)
  @impl true
  def stop(app, machine_id, opts \\ []), do: guarded(opts, fn -> Fly.stop_machine(app, machine_id, fly_opts(opts)) end)
  @impl true
  def suspend(app, machine_id, opts \\ []), do: guarded(opts, fn -> Fly.suspend_machine(app, machine_id, fly_opts(opts)) end)

  @doc """
  Roll a machine to a new image. Fly has no patch, so we GET the machine, swap `config.image`, and
  re-POST the full config (`Nexus.Fly.update_machine`). `{:ok, machine} | {:error,_} | {:skip,_}`.
  """
  @impl true
  def update_image(app, machine_id, image, opts \\ []) do
    guarded(opts, fn ->
      fo = fly_opts(opts)

      with {:ok, machine} <- Fly.get_machine(app, machine_id, fo),
           config when is_map(config) <- machine["config"] || machine[:config] do
        Fly.update_machine(app, machine_id, Map.put(config, "image", image), fo)
      else
        nil -> {:error, :no_machine_config}
        err -> err
      end
    end)
  end

  @doc "Destroy the machine, then the app (cascades the volume). `{:ok, :torn_down} | {:error,_} | {:skip,_}`."
  @impl true
  def teardown(app, machine_id, opts \\ []) do
    guarded(opts, fn ->
      fo = fly_opts(opts)
      _ = Fly.destroy_machine(app, machine_id, fo)
      _ = Fly.delete_app(app, fo)
      {:ok, :torn_down}
    end)
  end

  @doc """
  The Fly app name for a tenant. Deterministic + unique. Org ids (`org_MixedCase`) aren't valid Fly app
  names (DNS labels: lowercase alnum + dash), so we slug them — downcased alnum + an 8-char hash of the
  ORIGINAL id, which keeps distinct orgs distinct even when downcasing would collide.
  """
  @impl true
  def app_name(tenant), do: "cust-" <> fly_slug(tenant)

  defp fly_slug(tenant) do
    base = tenant |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "") |> String.slice(0, 30)
    hash = :crypto.hash(:sha256, tenant) |> Base.encode16(case: :lower) |> binary_part(0, 8)
    base <> "-" <> hash
  end

  # ── internals ──────────────────────────────────────────────────────────────────────────────────
  # Proceed if a token/transport is available (real or injected), else the feature is dark.
  defp ready?(opts), do: Keyword.has_key?(opts, :http) or present?(opts[:token]) or configured?()

  defp guarded(opts, fun), do: if(ready?(opts), do: fun.(), else: {:skip, :fly_not_configured})

  # Token resolves secret-first (broker side), overridable per-call; only network opts reach Nexus.Fly.
  defp fly_opts(opts) do
    token = opts[:token] || Nexus.Secrets.get("FLY_ORG_TOKEN") || ""
    [token: token] ++ Keyword.take(opts, [:http])
  end

  # FAIL-SAFE: NO default org. Customer machines must land in a DEDICATED org
  # (never the production/personal org that hosts wb-dogfood). If none is set,
  # `configured?` is false and every verb is dark — provisioning cannot happen.
  defp org_slug(opts),
    do: opts[:org_slug] || Nexus.Secrets.get("FLY_ORG_SLUG") || System.get_env("WB_FLY_ORG")

  # The autopoet machine config. Env is isolated by construction: NEXUS_TENANT is the owner, WB_DATA is
  # the mount, WB_PUBLIC_BEARER is a FRESH per-provision secret (borrowed from Nexus.Provisioner — never
  # shared/hardcoded). autostop:"suspend" + autostart:true = scale-to-near-zero (idle ⇒ storage only).
  defp machine_config(tenant, image, region, volume_id, bearer, opts) do
    port = opts[:port] || @internal_port

    %{
      "image" => image,
      "region" => region,
      "guest" => %{"cpu_kind" => "shared", "cpus" => 1, "memory_mb" => opts[:memory_mb] || @default_memory_mb},
      "mounts" => [%{"volume" => volume_id, "path" => "/data"}],
      "env" => %{
        "NEXUS_TENANT" => tenant,
        "WB_TENANT" => tenant,
        "WB_DATA" => "/data",
        "WB_PUBLIC_BEARER" => bearer,
        # nexus refuses to boot a deployed release without a real session secret (wb-nz88) — mint a fresh
        # one per provision (a re-provision invalidates old browser sessions, which is fine for a brain).
        "WB_SESSION_SECRET" => Base.encode64(:crypto.strong_rand_bytes(32)),
        # Route the brain's LLM through OUR Cloudflare AI Gateway — Nexus.Llm auto-detects these (llm.ex),
        # so every autopoet call goes through our gateway + gets metered, with no per-tenant provider keys.
        # Empty ⇒ absent (Nexus.Secrets.has? is false). Read from the control-plane's own secrets.
        "CF_AIG_URL" => Nexus.Secrets.get("CF_AIG_URL") || "",
        "CF_AIG_TOKEN" => Nexus.Secrets.get("CF_AIG_TOKEN") || "",
        # Port wiring for the deployed runtime image. `PORT` is the internal nexus HTTP port; the tenant
        # image binds its public/health server to the provisioned port. (NOTE wb-fhbko: `AUTOPOET_PORT`
        # is a product-specific env baked into the neutral runtime — a THE LINE violation. It's retained
        # for the current autopoet tenant image, which still reads it; the generic fix is a deploy-config
        # `provision-env` map so the runtime injects only neutral machine-identity env. Tracked separately.)
        "PORT" => "4000",
        "AUTOPOET_PORT" => Integer.to_string(port)
      },
      "services" => [
        %{
          "protocol" => "tcp",
          "internal_port" => port,
          "autostart" => true,
          "autostop" => "suspend",
          "min_machines_running" => 0,
          "ports" => [%{"port" => 443, "handlers" => ["tls", "http"]}]
        }
      ],
      "checks" => %{
        "health" => %{"type" => "http", "port" => port, "method" => "GET", "path" => "/status",
                      "interval" => "15s", "timeout" => "2s", "grace_period" => "10s"}
      },
      "restart" => %{"policy" => "on-failure"}
    }
  end

  defp id_of(%{"id" => id}) when is_binary(id), do: id
  defp id_of(%{id: id}) when is_binary(id), do: id
  defp id_of(_), do: nil

  defp rand_secret, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp present?(v), do: is_binary(v) and v != ""
  defp blank?(nil), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: true

  # Accept an org/tenant IDENTIFIER (alnum + _/-, no path-escape/space); app_name/1 then slugs it into a
  # Fly-safe DNS label. The security property (no `..`, no slash, bounded length) holds on the raw id.
  defp valid_tenant?(s) when is_binary(s), do: s =~ ~r/\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,62}\z/
  defp valid_tenant?(_), do: false
end
