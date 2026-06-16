defmodule Workbooks.NexusProvisioner do
  @moduledoc """
  Orchestrates the lifecycle of a single-tenant *nexus* — one Fly Machine per
  tenant org — by composing `Workbooks.FlyMachines` (the Fly REST client) with
  `Workbooks.NexusRegistry` (the org→nexus control-plane index). This is the layer
  that turns "org X wants a nexus" into a real Fly app + machine and a registry row
  the rest of the control plane reads.

  ## Ownership is checked on EVERY verb
  `teardown`/`wake`/`sleep`/`status` all verify ownership via the registry BEFORE
  touching Fly: a caller whose org does not own the nexus gets `{:error, :not_found}`
  and NO Fly action is taken. The registry's `get`/`owned_by?` are already scoped
  `WHERE org_id = ?`, so this provisioner reuses that single rule rather than
  re-deriving it.

  ## Secret scoping is the critical contract
  The per-nexus machine env is built PER NEXUS and is isolated by construction —
  nexus A can never receive nexus B's secrets:

    * `WB_TENANT` = the owning `org_id` (the tenancy key the machine boots under).
    * `WB_PUBLIC_BEARER` = a FRESH random secret minted per provision
      (`:crypto.strong_rand_bytes`). It is NEVER hardcoded and NEVER shared across
      nexuses — two provisions get two distinct bearers.
    * `WB_DATABASE_URL` = this nexus's own DSN (`opts[:database_url]`, may be `nil`).
    * `WB_STORAGE`/`WB_S3_PREFIX` = storage scoped to THIS tenant's prefix.

  Secrets are passed only into the Fly machine config (handed to the Fly client) —
  they are NEVER written to the registry row and NEVER logged. The registry stores
  only routing/identity metadata (`fly_app`, `fly_machine`, `region`, `plan`,
  `state`), never the bearer or DSN.

  ## Injectable Fly client
  `opts[:fly]` defaults to `Workbooks.FlyMachines`. A test passes a stub module that
  records calls without any network. The registry handle is `opts[:registry]`
  (defaults to a fresh `NexusRegistry.open()`), so tests can pin it to a temp DB.
  """
  alias Workbooks.NexusRegistry

  @default_region "sjc"
  @default_plan "starter"
  @runtime_image "ghcr.io/workbooks-sh/runtime:latest"

  # ── provision ───────────────────────────────────────────────────────────────────

  @doc """
  Provision a single-tenant nexus for `org_id`. Builds a deterministic,
  collision-safe Fly app name, mints a fresh per-nexus bearer, assembles the machine
  config (runtime image + scoped env + scale-to-zero), creates the Fly app + machine,
  then registers the `{id, org_id, fly_app, fly_machine, region, plan, state}` row.

  Returns `{:ok, nexus}` where `nexus` is the registry-shaped record plus a `:url`.
  The bearer/DSN are NOT in the returned record (they live only on the machine).
  """
  def provision(org_id, opts \\ []) do
    cond do
      blank?(org_id) ->
        {:error, :no_org}

      not valid_org_id?(org_id) ->
        # A malformed org_id (path-escape like "a/../shared", control/whitespace
        # chars) would corrupt WB_S3_PREFIX="tenants/<org>/" and escape the
        # per-tenant storage prefix. Reject fail-closed BEFORE any Fly action.
        {:error, :invalid_org}

      true ->
        fly = Keyword.get(opts, :fly, Workbooks.FlyMachines)
        # The registry MODULE is injectable (default NexusRegistry) so a test can
        # force a register failure and assert the orphan-cleanup path.
        reg = Keyword.get(opts, :registry_mod, NexusRegistry)
        h = Keyword.get(opts, :registry) || reg.open()
        # fly_org is a billing/trust boundary — pinned from server config, NEVER
        # caller opts. (opts[:fly] stays injectable for tests.)
        fly_org = System.get_env("WB_FLY_ORG", "personal")
        region = Keyword.get(opts, :region, @default_region)
        plan = Keyword.get(opts, :plan, @default_plan)

        # A nexus id that is NOT guessable/forgeable across orgs: it does not encode
        # the org_id, and the app name derives from the random id — so org B cannot
        # predict or collide org A's app name.
        nexus_id = "nx-" <> rand_token(12)
        fly_app = "nexus-" <> nexus_id
        # Friendly display name (what the user typed); the id stays the routing key.
        name = clean_name(Keyword.get(opts, :name)) || nexus_id

        # Per-nexus secrets — minted fresh, isolated, never shared.
        bearer = rand_secret()
        database_url = Keyword.get(opts, :database_url)
        env = build_env(org_id, bearer, database_url, opts)
        config = build_machine_config(env, region, opts)

        with {:ok, _app} <- fly.create_app(fly_app, fly_org, fly_opts(opts)),
             {:ok, machine} <- fly.create_machine(fly_app, config, fly_opts(opts)) do
          machine_id = machine_id(machine)

          attrs = %{
            id: nexus_id,
            org_id: org_id,
            name: name,
            fly_app: fly_app,
            fly_machine: machine_id,
            region: region,
            plan: plan,
            state: "created"
          }

          case reg.register(attrs, h) do
            {:ok, ^nexus_id} ->
              {:ok, Map.put(attrs, :url, "https://#{fly_app}.fly.dev")}

            {:error, reason} ->
              # The machine carries live secrets (bearer + DSN) but has no registry
              # row, so teardown (registry-gated) could never reach it. Best-effort
              # destroy the machine + app so no orphan with live secrets is left
              # running; ignore cleanup errors and surface the original failure.
              _ = fly.destroy_machine(fly_app, machine_id, fly_opts(opts))
              _ = if function_exported?(fly, :delete_app, 2),
                do: fly.delete_app(fly_app, fly_opts(opts)),
                else: :ok
              {:error, reason}
          end
        end
    end
  end

  # ── ownership-gated lifecycle verbs ──────────────────────────────────────────────

  @doc "Tear down a nexus: destroy the machine + Fly app, then the registry row. Ownership-gated."
  def teardown(nexus_id, org_id, opts \\ []) do
    with_owned(nexus_id, org_id, opts, fn nexus, fly, h ->
      _ = fly.destroy_machine(nexus.fly_app, nexus.fly_machine, fly_opts(opts))
      # Also delete the Fly app so a torn-down nexus leaves no suspended app shell
      # (the app IS the nexus). Best-effort: app cleanup must not block the registry
      # delete, else a half-deleted nexus stays visible/ownable.
      _ = if function_exported?(fly, :delete_app, 2), do: fly.delete_app(nexus.fly_app, fly_opts(opts)), else: :ok
      :ok = NexusRegistry.delete(nexus_id, org_id, h)
      {:ok, :torn_down}
    end)
  end

  @doc "Wake (start) a sleeping nexus's machine. Ownership-gated."
  def wake(nexus_id, org_id, opts \\ []) do
    with_owned(nexus_id, org_id, opts, fn nexus, fly, h ->
      with {:ok, _} <- fly.start_machine(nexus.fly_app, nexus.fly_machine, fly_opts(opts)) do
        NexusRegistry.set_state(nexus_id, org_id, "running", h)
      end
    end)
  end

  @doc "Sleep (stop) a running nexus's machine. Ownership-gated."
  def sleep(nexus_id, org_id, opts \\ []) do
    with_owned(nexus_id, org_id, opts, fn nexus, fly, h ->
      with {:ok, _} <- fly.stop_machine(nexus.fly_app, nexus.fly_machine, fly_opts(opts)) do
        NexusRegistry.set_state(nexus_id, org_id, "stopped", h)
      end
    end)
  end

  @doc "Fetch live machine status for a nexus. Ownership-gated."
  def status(nexus_id, org_id, opts \\ []) do
    with_owned(nexus_id, org_id, opts, fn nexus, fly, _h ->
      with {:ok, machine} <- fly.get_machine(nexus.fly_app, nexus.fly_machine, fly_opts(opts)) do
        {:ok, %{nexus: nexus, machine: machine}}
      end
    end)
  end

  # ── internals ────────────────────────────────────────────────────────────────────

  # The single ownership gate: resolve the org-scoped nexus FIRST; only if it exists
  # (i.e. the org owns it) do we hand the caller's fun the {nexus, fly, h}. A cross-org
  # / unknown id never reaches the fun, so no Fly call is made → `{:error, :not_found}`.
  defp with_owned(nexus_id, org_id, opts, fun) do
    fly = Keyword.get(opts, :fly, Workbooks.FlyMachines)
    h = Keyword.get(opts, :registry) || NexusRegistry.open()

    case NexusRegistry.get(nexus_id, org_id, h) do
      {:ok, nexus} -> fun.(nexus, fly, h)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  # Per-nexus env — built fresh per provision, isolated by org_id + per-nexus bearer.
  defp build_env(org_id, bearer, database_url, opts) do
    storage = Keyword.get(opts, :storage, "s3")

    base = %{
      "WB_WEB" => "1",
      "PORT" => "4000",
      "WB_TENANT" => org_id,
      "WB_TENANCY_MODE" => "single",
      "WB_PUBLIC_BEARER" => bearer,
      "WB_STORAGE" => storage,
      # Storage scoped to THIS tenant's prefix — never a shared/global prefix.
      "WB_S3_PREFIX" => "tenants/#{org_id}/"
    }

    if is_binary(database_url) and database_url != "",
      do: Map.put(base, "WB_DATABASE_URL", database_url),
      else: base
  end

  # Fly machine config — runtime image + scoped env + scale-to-zero (auto_stop=stop).
  defp build_machine_config(env, region, opts) do
    %{
      "image" => Keyword.get(opts, :image, @runtime_image),
      "region" => region,
      "env" => env,
      "guest" => %{
        "cpu_kind" => "shared",
        "cpus" => 1,
        "memory_mb" => Keyword.get(opts, :memory_mb, 1024)
      },
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

  # Thread only the network-relevant opts to the Fly client (e.g. an injected :http
  # or :token). Never leaks our :fly / :registry / secret opts into it. (`:stub` is a
  # test-only recorder hook the real FlyMachines simply ignores.)
  defp fly_opts(opts), do: Keyword.take(opts, [:http, :token, :stub])

  defp machine_id(%{"id" => id}) when is_binary(id), do: id
  defp machine_id(%{id: id}) when is_binary(id), do: id
  defp machine_id(_), do: nil

  # A fresh, URL-safe random secret (32 bytes of entropy) for the per-nexus bearer.
  defp rand_secret, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  # A short, collision-safe, non-guessable token for the nexus id / app name.
  # Hex keeps it to [a-z0-9] so it is always a valid Fly app-name segment.
  defp rand_token(bytes),
    do: bytes |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  # A friendly display name: trimmed, control-chars stripped, capped. nil/blank → nil
  # so the caller falls back to the nexus id.
  defp clean_name(name) when is_binary(name) do
    cleaned = name |> String.replace(~r/[\x00-\x1f\x7f]/, "") |> String.trim() |> String.slice(0, 60)
    if cleaned == "", do: nil, else: cleaned
  end

  defp clean_name(_), do: nil

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false

  # Strict org_id shape — the SAME rule enforced in NexusRegistry.register. Only
  # [a-zA-Z0-9_-] (must start alphanumeric), 1..63 chars. Rejects path-escape
  # ("a/../shared"), slashes, control/whitespace chars, and over-long ids, so the
  # value can be safely interpolated into WB_S3_PREFIX / WB_TENANT.
  defp valid_org_id?(s) when is_binary(s),
    do: s =~ ~r/\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,62}\z/

  defp valid_org_id?(_), do: false
end
