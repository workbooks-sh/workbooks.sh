defmodule Nexus.Provisioner do
  @moduledoc """
  Turns "org X wants a nexus" into a real Fly app + machine + a `Nexus.ControlPlane` registry row,
  composing `Nexus.Fly` (the Fly REST client) with the org-scoped registry.

  ## Ownership is checked on EVERY verb
  `teardown`/`wake`/`sleep`/`status` resolve the org-scoped nexus FIRST; a caller whose org does not
  own the nexus gets `{:error, :not_found}` and **no Fly action** is taken — the registry's
  `{org, kind, id}` scoping is the single rule, not re-derived per verb.

  ## Per-nexus secret isolation is the critical contract
  Machine env is built PER provision and isolated by construction — nexus A can never receive B's
  secrets: `WB_TENANT` = the owning org; `WB_PUBLIC_BEARER` = a FRESH random secret per provision
  (`:crypto.strong_rand_bytes`, never shared/hardcoded); `WB_S3_PREFIX` = `tenants/<org>/`. Secrets go
  ONLY into the Fly machine config — never into the registry row, never logged. The registry stores
  routing/identity only (`fly_app`, `fly_machine`, `region`, `plan`, `state`).

  The Fly client is injectable (`opts[:fly]` or `config :nexus, :fly_client`) so tests record calls
  with no network.
  """
  alias Nexus.ControlPlane, as: CP

  @default_region "sjc"

  @doc """
  Provision a single-tenant nexus for `org`. Validates the org (fail-closed against path-escape),
  mints a fresh per-nexus bearer, creates the Fly app + machine, then registers the row. On register
  failure the machine (which holds live secrets) is best-effort destroyed so no orphan is left.
  `{:ok, nexus}` (no bearer/DSN in the record) | `{:error, reason}`.
  """
  def provision(org, opts \\ []) do
    cond do
      blank?(org) -> {:error, :no_org}
      # A malformed org would corrupt WB_S3_PREFIX and escape the per-tenant prefix — reject BEFORE Fly.
      not valid_org?(org) -> {:error, :invalid_org}
      true -> do_provision(org, opts)
    end
  end

  defp do_provision(org, opts) do
    fly = fly_mod(opts)
    fly_org = System.get_env("WB_FLY_ORG") || "personal"
    region = Keyword.get(opts, :region, @default_region)
    # Default plan = the cheapest configured tier (operator config), not a hardcoded id.
    plan = Keyword.get(opts, :plan, Nexus.Pricing.default_tier().id)

    # Provider routing (wb-jr1py.1): the fleet lane's machine config is fly-shaped — refuse any other
    # provider EXPLICITLY rather than silently provisioning onto fly. (Edge apps deploy through the
    # cloudflare toolkit recipe / Nexus.Cloudflare, not as fleet machines.)
    provider = Keyword.get(opts, :provider, "fly")

    if provider != "fly" do
      {:error, {:unsupported_provider, provider}}
    else
      do_provision_fly(org, opts, fly, fly_org, region, plan)
    end
  end

  defp do_provision_fly(org, opts, fly, fly_org, region, plan) do

    # Non-guessable id (doesn't encode org → org B can't predict/collide org A's app name).
    nexus_id = "nx-" <> rand_token(12)
    fly_app = "nexus-" <> nexus_id
    name = clean_name(Keyword.get(opts, :name)) || nexus_id

    bearer = rand_secret()
    env = build_env(org, bearer, Keyword.get(opts, :database_url), opts)
    config = build_machine_config(env, region, opts)

    with {:ok, _app} <- fly.create_app(fly_app, fly_org, fly_opts(opts)),
         {:ok, machine} <- fly.create_machine(fly_app, config, fly_opts(opts)) do
      machine_id = machine_id(machine)

      attrs = %{
        name: name,
        fly_app: fly_app,
        fly_machine: machine_id,
        region: region,
        plan: plan,
        state: "created",
        url: "https://#{fly_app}.fly.dev"
      }

      case CP.put(org, :nexus, nexus_id, attrs) do
        {:ok, nx} ->
          {:ok, nx}

        {:error, reason} ->
          # The machine holds live secrets but has no registry row → teardown could never reach it.
          # Best-effort destroy so no orphan with live secrets is left running.
          _ = fly.destroy_machine(fly_app, machine_id, fly_opts(opts))
          _ = fly.delete_app(fly_app, fly_opts(opts))
          {:error, reason}
      end
    end
  end

  @doc "Tear down a nexus: destroy machine + Fly app, then the registry row. Ownership-gated."
  def teardown(nexus_id, org, opts \\ []) do
    with_owned(org, nexus_id, opts, fn nx, fly ->
      _ = fly.destroy_machine(nx.fly_app, nx.fly_machine, fly_opts(opts))
      _ = fly.delete_app(nx.fly_app, fly_opts(opts))
      :ok = CP.delete(org, :nexus, nexus_id)
      {:ok, :torn_down}
    end)
  end

  @doc "Wake (start) a sleeping nexus's machine. Ownership-gated."
  def wake(nexus_id, org, opts \\ []) do
    with_owned(org, nexus_id, opts, fn nx, fly ->
      with {:ok, _} <- fly.start_machine(nx.fly_app, nx.fly_machine, fly_opts(opts)),
           do: CP.update(org, :nexus, nexus_id, %{state: "running"})
    end)
  end

  @doc "Sleep (stop) a running nexus's machine. Ownership-gated."
  def sleep(nexus_id, org, opts \\ []) do
    with_owned(org, nexus_id, opts, fn nx, fly ->
      with {:ok, _} <- fly.stop_machine(nx.fly_app, nx.fly_machine, fly_opts(opts)),
           do: CP.update(org, :nexus, nexus_id, %{state: "stopped"})
    end)
  end

  @doc "Live machine status for a nexus. Ownership-gated."
  def status(nexus_id, org, opts \\ []) do
    with_owned(org, nexus_id, opts, fn nx, fly ->
      with {:ok, machine} <- fly.get_machine(nx.fly_app, nx.fly_machine, fly_opts(opts)),
           do: {:ok, %{nexus: nx, machine: machine}}
    end)
  end

  # ── internals ──────────────────────────────────────────────────────────────────────────────
  # The single ownership gate: resolve the org-scoped nexus FIRST; a cross-org/unknown id never
  # reaches the fun → no Fly call → {:error, :not_found}.
  defp with_owned(org, nexus_id, opts, fun) do
    case CP.get(org, :nexus, nexus_id) do
      {:ok, nx} -> fun.(nx, fly_mod(opts))
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  # Injectable Fly client: opts[:fly] (tests) → config → the real Nexus.Fly.
  defp fly_mod(opts), do: Keyword.get(opts, :fly) || Application.get_env(:nexus, :fly_client, Nexus.Fly)

  defp build_env(org, bearer, database_url, opts) do
    base = %{
      "WB_SERVE" => "1",
      "PORT" => "4000",
      "WB_TENANT" => org,
      "NEXUS_TENANT" => org,
      "WB_PUBLIC_BEARER" => bearer,
      "WB_STORAGE" => Keyword.get(opts, :storage, "s3"),
      "WB_S3_PREFIX" => "tenants/#{org}/"
    }

    if is_binary(database_url) and database_url != "",
      do: Map.put(base, "WB_DATABASE_URL", database_url),
      else: base
  end

  defp build_machine_config(env, region, opts) do
    # Every image ref — incl. a caller-supplied opts[:image] / WB_IMAGE — passes the ArtifactTrust seam
    # before it is deployed: an untrusted registry is refused (fail closed), a pinned repo is digest-pinned
    # (red-team wb-skhj). Neutral by default; our DeployKit declares the allowlist + pins.
    %{
      "image" => Nexus.ArtifactTrust.resolve!(Keyword.get(opts, :image, Nexus.Config.runtime_image())),
      "region" => region,
      "env" => env,
      "guest" => %{"cpu_kind" => "shared", "cpus" => 1, "memory_mb" => Keyword.get(opts, :memory_mb, 1024)},
      "services" => [
        %{
          "protocol" => "tcp",
          "internal_port" => 4000,
          "autostop" => "stop",
          "autostart" => true,
          "min_machines_running" => 0,
          "ports" => [
            %{"port" => 443, "handlers" => ["tls", "http"]},
            %{"port" => 80, "handlers" => ["http"]}
          ]
        }
      ]
    }
  end

  # Only network-relevant opts reach the Fly client — never our :fly / secret opts.
  defp fly_opts(opts), do: Keyword.take(opts, [:http, :token])

  defp machine_id(%{"id" => id}) when is_binary(id), do: id
  defp machine_id(%{id: id}) when is_binary(id), do: id
  defp machine_id(_), do: nil

  defp rand_secret, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  defp rand_token(bytes), do: bytes |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp clean_name(name) when is_binary(name) do
    cleaned = name |> String.replace(~r/[\x00-\x1f\x7f]/, "") |> String.trim() |> String.slice(0, 60)
    if cleaned == "", do: nil, else: cleaned
  end

  defp clean_name(_), do: nil

  defp blank?(nil), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false

  # Strict org shape — only [a-zA-Z0-9_-], must start alphanumeric, 1..63 chars. Rejects path-escape
  # ("a/../shared"), slashes, control/whitespace, over-long — safe to interpolate into WB_S3_PREFIX.
  defp valid_org?(s) when is_binary(s), do: s =~ ~r/\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,62}\z/
  defp valid_org?(_), do: false
end
