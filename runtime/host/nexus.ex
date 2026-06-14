defmodule Workbooks.Nexus do
  @moduledoc """
  The high-level product operations the control-plane API calls to manage a
  tenant org's *nexuses* (single-tenant compute homes). This is the orchestration
  layer that COMPOSES the lower seams — billing entitlements
  (`Workbooks.Billing.Polar`), per-tenant Postgres (`Workbooks.Neon`), Fly machine
  lifecycle (`Workbooks.NexusProvisioner`), and the control-plane index
  (`Workbooks.NexusRegistry`) — into the verbs a user (or the PCP) drives:
  `create_nexus`, `delete_nexus`, `list_nexuses`, `nexus_status`, `wake_nexus`,
  `sleep_nexus`.

  ## The two product invariants this layer owns

  1. **Entitlement is checked BEFORE any resource is created (fail-closed).**
     `create_nexus` resolves the org's entitlement FIRST. If billing says the org
     may not provision — or billing can't be reached, or the subscription is
     inactive — we return `{:error, :not_entitled}` and touch NOTHING: no Neon
     project, no Fly machine. Over-limit (`registry.list/1` count already at
     `max_nexuses`) is refused the same way with `{:error, :nexus_limit}`.

  2. **`org_id` is the boundary on EVERY verb.** We never re-derive a weaker
     ownership check here — every mutation is delegated to the already
     org-scoped provisioner/registry (their `get`/`teardown`/`wake`/`sleep`/`status`
     are `WHERE org_id = ?` / ownership-gated), and we always thread `org_id`
     through. A caller can never act on another org's nexus.

  ## Rollback
  If a DB-addon plan creates a Neon project and the Fly provision then fails, we
  best-effort `neon.delete_project` so no orphaned tenant database is left behind,
  and surface the provision error.

  ## Injectable collaborators
  Every collaborator is injectable via `opts` (defaulting to the real module), so
  the whole layer is unit-testable with NO network:

    * `opts[:billing]`     — default `Workbooks.Billing.Polar`
    * `opts[:neon]`        — default `Workbooks.Neon`
    * `opts[:provisioner]` — default `Workbooks.NexusProvisioner`
    * `opts[:registry]`    — default `Workbooks.NexusRegistry`
  """

  @doc """
  Create a nexus for `org_id` on `plan` after an entitlement gate.

  Steps, in order (each later step only runs if every earlier one passed):

    1. **Entitlement gate (fail-closed, FIRST).** Resolve the org's entitlement —
       either `opts[:entitlement]` passed directly by the PCP, or
       `billing.get_subscription(opts[:subscription_id])` then
       `billing.entitlements(sub)`. If `can_provision` is not `true` →
       `{:error, :not_entitled}` and NOTHING is created.
    2. **Over-limit gate.** `registry.list(org_id)` count must be
       `< entitlement.max_nexuses`, else `{:error, :nexus_limit}`.
    3. **DB addon (optional).** If the plan includes a DB addon,
       `neon.create_project/2` → extract the DSN. On Neon failure, abort with the
       error (nothing else created).
    4. **Provision.** `provisioner.provision(org_id, plan: plan, database_url: dsn, ...)`.
    5. **Rollback.** If provision fails AFTER a Neon project was created,
       best-effort `neon.delete_project` to avoid an orphaned DB, then return the
       provision error.
    6. **Persist the DB id (fail-closed).** For a DB-addon nexus, record the Neon
       `neon_project_id` on the registry row via `registry.update/3`. If that
       persistence fails, roll back fail-closed (best-effort `provisioner.teardown`
       + `neon.delete_project`) and return an error — we never leave a nexus whose
       DB project id was never recorded (that is exactly the orphan we are closing).
    7. Return the nexus record `{:ok, nexus}`.

  ## Org validation (cheap, FIRST)
  `org_id` shape is validated at the very TOP — before any Neon project is created —
  so a malformed `org_id` returns `{:error, :invalid_org}` and never wastes/orphans a
  Neon project.

  ## Known limitation — limit check is best-effort (TOCTOU)
  The over-limit gate (`registry.list/1` count `< max_nexuses`) is a
  read-then-act check with no lock, so two concurrent `create_nexus` calls for the
  same org can BOTH observe `count == max-1` and both provision, briefly exceeding
  `max_nexuses` by one. A true fix needs a DB-level count constraint or a row
  lock/serialized counter at the registry; that is intentionally NOT done here to
  avoid over-engineering. Follow-up: DB-enforced per-org nexus quota.
  """
  def create_nexus(org_id, plan, opts \\ []) do
    billing = Keyword.get(opts, :billing, Workbooks.Billing.Polar)
    neon = Keyword.get(opts, :neon, Workbooks.Neon)
    provisioner = Keyword.get(opts, :provisioner, Workbooks.NexusProvisioner)
    registry = Keyword.get(opts, :registry, Workbooks.NexusRegistry)

    # Validate org_id shape FIRST — before any Neon project is created — so a bad
    # org_id can't cause a wasted/orphaned Neon project. Reuses the registry's
    # shape rule (same regex as NexusRegistry/NexusProvisioner).
    with :ok <- check_org_id(org_id),
         {:ok, ent} <- resolve_entitlement(billing, opts),
         :ok <- check_can_provision(ent),
         :ok <- check_under_limit(registry, org_id, ent),
         {:ok, dsn, neon_project_id} <- maybe_create_db(neon, plan, org_id, opts) do
      provision_opts =
        opts
        |> collaborator_opts()
        |> Keyword.put(:plan, plan)
        |> Keyword.put(:database_url, dsn)

      case provisioner.provision(org_id, provision_opts) do
        {:ok, nexus} ->
          persist_neon_project_id(nexus, neon_project_id, registry, provisioner, neon, org_id, opts)

        {:error, reason} ->
          # Provision failed AFTER a Neon project was created → best-effort delete
          # it so we don't leak an orphaned tenant DB. Ignore cleanup errors and
          # surface the ORIGINAL provision failure.
          if neon_project_id, do: _ = neon.delete_project(neon_project_id, neon_opts(opts))
          {:error, reason}
      end
    end
  end

  # After a successful provision, persist the Neon project id onto the registry row
  # so delete_nexus can later release the tenant DB. Without this the project id is
  # lost and the tenant Postgres leaks forever on delete. If there is no DB addon
  # (neon_project_id == nil) there is nothing to persist. If persistence FAILS we roll
  # back fail-closed rather than leave a nexus whose DB id was never recorded.
  defp persist_neon_project_id(nexus, nil, _registry, _provisioner, _neon, _org_id, _opts),
    do: {:ok, nexus}

  defp persist_neon_project_id(nexus, project_id, registry, provisioner, neon, org_id, opts) do
    nexus_id = nexus_id(nexus)

    case registry.update(nexus_id, org_id, %{neon_project_id: project_id}) do
      {:ok, _row} ->
        {:ok, nexus}

      _failed ->
        # Could not record the DB project id → the orphan we are closing would be
        # re-introduced (delete would never find the id). Roll back fail-closed:
        # tear the nexus down and delete the just-created Neon project.
        _ = provisioner.teardown(nexus_id, org_id, provisioner_opts(opts))
        _ = neon.delete_project(project_id, neon_opts(opts))
        {:error, :persist_failed}
    end
  end

  defp nexus_id(%{id: id}), do: id
  defp nexus_id(%{"id" => id}), do: id
  defp nexus_id(_), do: nil

  @doc """
  Delete a nexus. Ownership-gated: `provisioner.teardown(nexus_id, org_id)` itself
  verifies the org owns the nexus (returns `{:error, :not_found}` otherwise and
  takes no action). Best-effort `neon.delete_project` if the nexus carried a DB so
  the tenant Postgres is released too.
  """
  def delete_nexus(nexus_id, org_id, opts \\ []) do
    provisioner = Keyword.get(opts, :provisioner, Workbooks.NexusProvisioner)
    neon = Keyword.get(opts, :neon, Workbooks.Neon)
    registry = Keyword.get(opts, :registry, Workbooks.NexusRegistry)

    # Resolve the nexus FIRST (org-scoped) so we can release its DB after teardown.
    # A cross-org / unknown id never resolves → teardown returns :not_found and we
    # never touch Neon.
    db_id = owned_db_project_id(registry, nexus_id, org_id, opts)

    case provisioner.teardown(nexus_id, org_id, provisioner_opts(opts)) do
      {:ok, result} ->
        if db_id, do: _ = neon.delete_project(db_id, neon_opts(opts))
        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "List ONLY `org_id`'s nexuses. Delegates to the org-scoped registry."
  def list_nexuses(org_id, opts \\ []) do
    registry = Keyword.get(opts, :registry, Workbooks.NexusRegistry)
    registry.list(org_id)
  end

  @doc "Live status for a nexus, ownership-gated downstream in the provisioner."
  def nexus_status(nexus_id, org_id, opts \\ []) do
    provisioner = Keyword.get(opts, :provisioner, Workbooks.NexusProvisioner)
    provisioner.status(nexus_id, org_id, provisioner_opts(opts))
  end

  @doc "Wake (start) a nexus, ownership-gated downstream in the provisioner."
  def wake_nexus(nexus_id, org_id, opts \\ []) do
    provisioner = Keyword.get(opts, :provisioner, Workbooks.NexusProvisioner)
    provisioner.wake(nexus_id, org_id, provisioner_opts(opts))
  end

  @doc "Sleep (stop) a nexus, ownership-gated downstream in the provisioner."
  def sleep_nexus(nexus_id, org_id, opts \\ []) do
    provisioner = Keyword.get(opts, :provisioner, Workbooks.NexusProvisioner)
    provisioner.sleep(nexus_id, org_id, provisioner_opts(opts))
  end

  # ── entitlement gate ─────────────────────────────────────────────────────────────

  # Resolve the org's entitlement. The PCP may pass it directly (`opts[:entitlement]`)
  # to avoid a billing round-trip; otherwise fetch the subscription and map it.
  # Fails CLOSED: any billing error → `{:error, :not_entitled}` (we never default to
  # "allowed" when billing can't be reached).
  defp resolve_entitlement(billing, opts) do
    case Keyword.get(opts, :entitlement) do
      ent when is_map(ent) ->
        {:ok, ent}

      _ ->
        case billing.get_subscription(Keyword.get(opts, :subscription_id), billing_opts(opts)) do
          {:ok, sub} -> {:ok, billing.entitlements(sub)}
          # Billing unreachable / subscription missing → fail closed.
          {:error, _} -> {:error, :not_entitled}
        end
    end
  end

  defp check_can_provision(%{can_provision: true}), do: :ok
  defp check_can_provision(_), do: {:error, :not_entitled}

  # Validate org_id shape (same strict rule as NexusRegistry/NexusProvisioner) at the
  # TOP of create_nexus, before any Neon project is created. A malformed org_id can
  # never waste/orphan a Neon project.
  defp check_org_id(s) when is_binary(s) do
    if s =~ ~r/\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,62}\z/, do: :ok, else: {:error, :invalid_org}
  end

  defp check_org_id(_), do: {:error, :invalid_org}

  defp check_under_limit(registry, org_id, ent) do
    max = Map.get(ent, :max_nexuses, 0)
    count = registry.list(org_id) |> length()
    if count < max, do: :ok, else: {:error, :nexus_limit}
  end

  # ── DB addon ─────────────────────────────────────────────────────────────────────

  # If the plan includes a DB addon, create a Neon project for THIS tenant and pull
  # its DSN. Returns `{:ok, dsn, project_id}` (project_id drives rollback) or, when
  # there is no addon, `{:ok, nil, nil}`. A Neon failure aborts create_nexus with the
  # error — nothing else is created.
  defp maybe_create_db(neon, plan, org_id, opts) do
    if db_addon?(plan) do
      name = "nexus-#{org_id}"

      case neon.create_project(name, neon_opts(opts)) do
        {:ok, body} ->
          dsn = extract_dsn(body)
          project_id = extract_project_id(body)

          # Nil-DSN guard: a DB-backed nexus MUST boot with a real DSN. If the Neon
          # response carried no connection_uri/DSN, fail closed and best-effort delete
          # the just-created project so we don't provision a DB nexus with a nil DSN
          # (and don't leak the project either).
          if is_binary(dsn) and dsn != "" do
            {:ok, dsn, project_id}
          else
            if project_id, do: _ = neon.delete_project(project_id, neon_opts(opts))
            {:error, :neon_dsn_missing}
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok, nil, nil}
    end
  end

  # A plan "includes a DB addon" if it is the map/keyword shape carrying an addons
  # list with :db, or a string tier we treat as DB-backed. Kept permissive so the
  # control plane can pass either a tier string or a structured plan.
  defp db_addon?(plan) when is_map(plan), do: addon_member?(Map.get(plan, :addons) || Map.get(plan, "addons"))
  defp db_addon?(plan) when is_list(plan), do: addon_member?(Keyword.get(plan, :addons))
  defp db_addon?(_), do: false

  defp addon_member?(addons) when is_list(addons),
    do: Enum.any?(addons, &(&1 in [:db, "db", :database, "database", :postgres, "postgres"]))

  defp addon_member?(_), do: false

  # Pull the pooled DSN out of a Neon create-project body. The body carries a
  # `connection_uris` array, each entry with a `connection_uri` string.
  defp extract_dsn(%{"connection_uris" => [%{"connection_uri" => uri} | _]}) when is_binary(uri), do: uri
  defp extract_dsn(%{"connection_uris" => [uri | _]}) when is_binary(uri), do: uri
  defp extract_dsn(_), do: nil

  defp extract_project_id(%{"project" => %{"id" => id}}) when is_binary(id), do: id
  defp extract_project_id(%{"id" => id}) when is_binary(id), do: id
  defp extract_project_id(_), do: nil

  # ── delete helpers ───────────────────────────────────────────────────────────────

  # The Neon project id for an owned nexus, if it has one (the registry's dedicated
  # `neon_project_id` column, persisted at create time, or nil). Org-scoped: a
  # non-owned nexus resolves to nil and no Neon delete is attempted. Read BEFORE
  # teardown, since teardown destroys the registry row.
  defp owned_db_project_id(registry, nexus_id, org_id, _opts) do
    case safe_get(registry, nexus_id, org_id) do
      {:ok, %{neon_project_id: pid}} -> pid
      {:ok, %{"neon_project_id" => pid}} -> pid
      _ -> nil
    end
  end

  # Registry.get/3 is org-scoped; guard the call so a missing handle never crashes
  # the delete path (the provisioner teardown remains the authoritative gate).
  defp safe_get(registry, nexus_id, org_id) do
    try do
      registry.get(nexus_id, org_id)
    rescue
      _ -> {:error, :not_found}
    end
  end

  # ── opts plumbing ────────────────────────────────────────────────────────────────

  # Strip our orchestration-only keys before threading opts into a collaborator. We
  # DROP the keys this layer owns (so a Fly/Neon/Polar client never receives
  # :billing/:provisioner/:entitlement/…) and pass the rest through — the real
  # clients read only the keys they know (`:http`/`:token`/`:fly`/…) and ignore the
  # rest, while a test stub can ride additional injected keys on the same opts.
  @orchestration_keys [:billing, :neon, :provisioner, :registry, :entitlement, :subscription_id]

  defp collaborator_opts(opts), do: Keyword.drop(opts, @orchestration_keys)
  defp neon_opts(opts), do: collaborator_opts(opts)
  defp billing_opts(opts), do: collaborator_opts(opts)
  defp provisioner_opts(opts), do: collaborator_opts(opts)
end
