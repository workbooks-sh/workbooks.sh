defmodule Workbooks.NexusTest do
  @moduledoc """
  Unit tests for the `Workbooks.Nexus` orchestration layer with ALL collaborators
  stubbed — no network, no DB, no Fly/Neon/Polar. Each stub records its calls into
  the test process mailbox (or an Agent) so we can assert BOTH the result AND that
  the fail-closed gates short-circuit BEFORE any resource is created.

  The contracts asserted:
    * entitlement gate is FIRST and fail-closed (no provisioner/neon touched);
    * over-limit gate refuses at max_nexuses;
    * DB-addon path creates the Neon project then provisions WITH the DSN;
    * a provision failure after a Neon project was created rolls the project back;
    * happy path returns the provisioned nexus;
    * delete/list/status/wake/sleep thread org_id and a non-owned nexus is refused.
  """
  use ExUnit.Case, async: true

  alias Workbooks.Nexus

  setup do
    {:ok, calls} = Agent.start_link(fn -> [] end)
    on_exit(fn -> if Process.alive?(calls), do: Agent.stop(calls) end)
    %{calls: calls}
  end

  defp calls(calls), do: Agent.get(calls, &Enum.reverse(&1))
  defp called?(calls, tag), do: Enum.any?(calls(calls), &match?({^tag, _}, &1))

  # ── stub collaborators ──────────────────────────────────────────────────────────
  # Each stub reads its scripted behaviour + the recorder Agent from the test's opts.

  defmodule StubBilling do
    def get_subscription(id, opts) do
      Agent.update(opts[:calls], &[{:billing_get_subscription, id} | &1])
      opts[:subscription_result] || {:ok, %{"status" => "active"}}
    end

    def entitlements(_sub), do: %{can_provision: true, max_nexuses: 3, seats: 3, storage_quota_bytes: 0}
  end

  defmodule StubNeon do
    def create_project(name, opts) do
      Agent.update(opts[:calls], &[{:neon_create_project, name} | &1])
      opts[:neon_result] ||
        {:ok,
         %{
           "project" => %{"id" => "proj-123"},
           "connection_uris" => [%{"connection_uri" => "postgres://dsn"}]
         }}
    end

    def delete_project(id, opts) do
      Agent.update(opts[:calls], &[{:neon_delete_project, id} | &1])
      {:ok, %{}}
    end
  end

  defmodule StubProvisioner do
    def provision(org_id, opts) do
      Agent.update(opts[:calls], &[{:provision, {org_id, opts[:database_url], opts[:plan]}} | &1])
      opts[:provision_result] || {:ok, %{id: "nx-abc", org_id: org_id, state: "created"}}
    end

    def teardown(nexus_id, org_id, opts) do
      Agent.update(opts[:calls], &[{:teardown, {nexus_id, org_id}} | &1])
      opts[:teardown_result] || {:ok, :torn_down}
    end

    def status(nexus_id, org_id, opts) do
      Agent.update(opts[:calls], &[{:status, {nexus_id, org_id}} | &1])
      opts[:status_result] || {:ok, %{nexus: %{id: nexus_id}}}
    end

    def wake(nexus_id, org_id, opts) do
      Agent.update(opts[:calls], &[{:wake, {nexus_id, org_id}} | &1])
      opts[:wake_result] || {:ok, %{id: nexus_id, state: "running"}}
    end

    def sleep(nexus_id, org_id, opts) do
      Agent.update(opts[:calls], &[{:sleep, {nexus_id, org_id}} | &1])
      opts[:sleep_result] || {:ok, %{id: nexus_id, state: "stopped"}}
    end
  end

  defmodule StubRegistry do
    def list(org_id) do
      {calls, results} = lookup(org_id)
      Agent.update(calls, &[{:list, org_id} | &1])
      results[:list] || []
    end

    def get(nexus_id, org_id) do
      {calls, results} = lookup(org_id)
      Agent.update(calls, &[{:get, {nexus_id, org_id}} | &1])
      results[:get] || {:error, :not_found}
    end

    def update(nexus_id, org_id, attrs) do
      {calls, results} = lookup(org_id)
      Agent.update(calls, &[{:update, {nexus_id, org_id, attrs}} | &1])
      results[:update] || {:ok, Map.merge(%{id: nexus_id, org_id: org_id}, attrs)}
    end

    # The registry is called with org_id only (arity 1/2), but we need the test's
    # recorder + scripted results. We stash them in the process dictionary of the
    # test via a registered key passed through the test context.
    defp lookup(_org_id) do
      {Process.get(:nexus_test_calls), Process.get(:nexus_test_registry_results, %{})}
    end
  end

  # Common opts builder: injects all four stubs + the recorder + scripted results.
  defp base_opts(ctx, extra) do
    Process.put(:nexus_test_calls, ctx.calls)
    Process.put(:nexus_test_registry_results, Keyword.get(extra, :registry_results, %{}))

    [
      billing: StubBilling,
      neon: StubNeon,
      provisioner: StubProvisioner,
      registry: StubRegistry,
      calls: ctx.calls
    ] ++ Keyword.drop(extra, [:registry_results])
  end

  # ── entitlement gate (fail-closed, FIRST) ───────────────────────────────────────

  test "create_nexus is refused when entitlement.can_provision is false; nothing created", ctx do
    opts =
      base_opts(ctx,
        entitlement: %{can_provision: false, max_nexuses: 0, seats: 0, storage_quota_bytes: 0}
      )

    assert {:error, :not_entitled} = Nexus.create_nexus("acme", %{addons: [:db]}, opts)

    refute called?(ctx.calls, :provision)
    refute called?(ctx.calls, :neon_create_project)
  end

  test "create_nexus fails closed when billing.get_subscription errors", ctx do
    opts = base_opts(ctx, subscription_result: {:error, {404, %{}}})

    assert {:error, :not_entitled} = Nexus.create_nexus("acme", "starter", opts)
    refute called?(ctx.calls, :provision)
    refute called?(ctx.calls, :neon_create_project)
  end

  # ── over-limit gate ─────────────────────────────────────────────────────────────

  test "create_nexus is refused at max_nexuses; nothing created", ctx do
    existing = [%{id: "nx-1"}, %{id: "nx-2"}, %{id: "nx-3"}]

    opts =
      base_opts(ctx,
        entitlement: %{can_provision: true, max_nexuses: 3, seats: 3, storage_quota_bytes: 0},
        registry_results: %{list: existing}
      )

    assert {:error, :nexus_limit} = Nexus.create_nexus("acme", %{addons: [:db]}, opts)

    refute called?(ctx.calls, :provision)
    refute called?(ctx.calls, :neon_create_project)
  end

  # ── DB-addon path ───────────────────────────────────────────────────────────────

  test "DB-addon plan creates the Neon project then provisions WITH the DSN", ctx do
    opts =
      base_opts(ctx,
        entitlement: %{can_provision: true, max_nexuses: 3, seats: 3, storage_quota_bytes: 0}
      )

    assert {:ok, %{id: "nx-abc"}} = Nexus.create_nexus("acme", %{addons: [:db]}, opts)

    assert called?(ctx.calls, :neon_create_project)
    # provision was called with the DSN extracted from the Neon body.
    assert Enum.any?(calls(ctx.calls), fn
             {:provision, {"acme", "postgres://dsn", _plan}} -> true
             _ -> false
           end)

    # ORDER: neon project created BEFORE provision.
    seq = calls(ctx.calls) |> Enum.map(&elem(&1, 0))
    assert Enum.find_index(seq, &(&1 == :neon_create_project)) <
             Enum.find_index(seq, &(&1 == :provision))
  end

  # BLOCKER (HIGH) regression: after a DB-addon provision, the Neon project id must
  # be PERSISTED onto the registry row (real path, not a hand-injected addons field).
  # Without this the project id is lost and the tenant Postgres leaks on delete.
  test "create_nexus persists neon_project_id after a DB-addon provision", ctx do
    opts =
      base_opts(ctx,
        entitlement: %{can_provision: true, max_nexuses: 3, seats: 3, storage_quota_bytes: 0}
      )

    assert {:ok, _} = Nexus.create_nexus("acme", %{addons: [:db]}, opts)

    # registry.update was called with the project id extracted from the Neon body,
    # scoped to the provisioned nexus id + org.
    assert Enum.any?(calls(ctx.calls), fn
             {:update, {"nx-abc", "acme", %{neon_project_id: "proj-123"}}} -> true
             _ -> false
           end)

    # ORDER: provision BEFORE the persist update.
    seq = calls(ctx.calls) |> Enum.map(&elem(&1, 0))
    assert Enum.find_index(seq, &(&1 == :provision)) <
             Enum.find_index(seq, &(&1 == :update))
  end

  # If persisting the project id FAILS, roll back fail-closed: tear the nexus down and
  # delete the just-created Neon project, then return an error — never leave a nexus
  # whose DB id was never recorded (that would re-introduce the orphan).
  test "create_nexus rolls back fail-closed when neon_project_id persistence fails", ctx do
    opts =
      base_opts(ctx,
        entitlement: %{can_provision: true, max_nexuses: 3, seats: 3, storage_quota_bytes: 0},
        registry_results: %{update: {:error, :db_down}}
      )

    assert {:error, :persist_failed} = Nexus.create_nexus("acme", %{addons: [:db]}, opts)

    assert Enum.any?(calls(ctx.calls), &match?({:teardown, {"nx-abc", "acme"}}, &1))
    assert Enum.any?(calls(ctx.calls), &match?({:neon_delete_project, "proj-123"}, &1))
  end

  # No-DB plan: nothing to persist, so registry.update is NOT called.
  test "create_nexus does not persist neon_project_id for a no-DB plan", ctx do
    opts =
      base_opts(ctx,
        entitlement: %{can_provision: true, max_nexuses: 3, seats: 3, storage_quota_bytes: 0}
      )

    assert {:ok, _} = Nexus.create_nexus("acme", "starter", opts)
    refute called?(ctx.calls, :update)
  end

  # ── org_id validation (cheap, FIRST) ────────────────────────────────────────────

  # A malformed org_id must be rejected at the TOP, before any Neon project is created
  # (no wasted/orphaned project). Pre-fix create_nexus never validated org_id, so a
  # path-escape org_id reached neon.create_project.
  test "create_nexus rejects a malformed org_id before touching Neon", ctx do
    opts =
      base_opts(ctx,
        entitlement: %{can_provision: true, max_nexuses: 3, seats: 3, storage_quota_bytes: 0}
      )

    for bad <- ["a/../shared", "a/b", "org a", String.duplicate("x", 200)] do
      assert {:error, :invalid_org} = Nexus.create_nexus(bad, %{addons: [:db]}, opts)
    end

    refute called?(ctx.calls, :neon_create_project)
    refute called?(ctx.calls, :provision)
  end

  # ── nil-DSN guard ────────────────────────────────────────────────────────────────

  # If the Neon response lacks a connection_uri/DSN, fail closed and best-effort delete
  # the just-created project — never provision a DB nexus with a nil DSN.
  test "create_nexus fails closed and deletes the project when the Neon DSN is missing", ctx do
    opts =
      base_opts(ctx,
        entitlement: %{can_provision: true, max_nexuses: 3, seats: 3, storage_quota_bytes: 0},
        neon_result: {:ok, %{"project" => %{"id" => "proj-nodsn"}, "connection_uris" => []}}
      )

    assert {:error, :neon_dsn_missing} = Nexus.create_nexus("acme", %{addons: [:db]}, opts)

    # The just-created (DSN-less) project is cleaned up; provision is never reached.
    assert Enum.any?(calls(ctx.calls), &match?({:neon_delete_project, "proj-nodsn"}, &1))
    refute called?(ctx.calls, :provision)
  end

  test "no-DB plan provisions WITHOUT a Neon project and a nil DSN", ctx do
    opts =
      base_opts(ctx,
        entitlement: %{can_provision: true, max_nexuses: 3, seats: 3, storage_quota_bytes: 0}
      )

    assert {:ok, _} = Nexus.create_nexus("acme", "starter", opts)
    refute called?(ctx.calls, :neon_create_project)

    assert Enum.any?(calls(ctx.calls), fn
             {:provision, {"acme", nil, "starter"}} -> true
             _ -> false
           end)
  end

  # ── rollback ────────────────────────────────────────────────────────────────────

  test "provision failure after a Neon project was created rolls back neon.delete_project", ctx do
    opts =
      base_opts(ctx,
        entitlement: %{can_provision: true, max_nexuses: 3, seats: 3, storage_quota_bytes: 0},
        provision_result: {:error, :fly_boom}
      )

    assert {:error, :fly_boom} = Nexus.create_nexus("acme", %{addons: [:db]}, opts)

    # The orphaned tenant DB is cleaned up with the project id from the Neon body.
    assert Enum.any?(calls(ctx.calls), &match?({:neon_delete_project, "proj-123"}, &1))
  end

  test "provision failure with NO DB addon does not call neon.delete_project", ctx do
    opts =
      base_opts(ctx,
        entitlement: %{can_provision: true, max_nexuses: 3, seats: 3, storage_quota_bytes: 0},
        provision_result: {:error, :fly_boom}
      )

    assert {:error, :fly_boom} = Nexus.create_nexus("acme", "starter", opts)
    refute called?(ctx.calls, :neon_delete_project)
  end

  # ── happy path ──────────────────────────────────────────────────────────────────

  test "happy path returns the provisioned nexus record", ctx do
    opts =
      base_opts(ctx,
        entitlement: %{can_provision: true, max_nexuses: 3, seats: 3, storage_quota_bytes: 0}
      )

    assert {:ok, %{id: "nx-abc", org_id: "acme"}} = Nexus.create_nexus("acme", "starter", opts)
  end

  # ── lifecycle verbs thread org_id and are ownership-gated ───────────────────────

  test "list_nexuses delegates to the org-scoped registry with org_id", ctx do
    opts = base_opts(ctx, registry_results: %{list: [%{id: "nx-1"}]})
    assert [%{id: "nx-1"}] = Nexus.list_nexuses("acme", opts)
    assert called?(ctx.calls, :list)
  end

  test "delete_nexus threads org_id to teardown and is refused for a non-owned nexus", ctx do
    # Stub registry.get → not_found (non-owned), teardown → not_found.
    opts = base_opts(ctx, teardown_result: {:error, :not_found}, registry_results: %{get: {:error, :not_found}})

    assert {:error, :not_found} = Nexus.delete_nexus("nx-other", "acme", opts)
    assert Enum.any?(calls(ctx.calls), &match?({:teardown, {"nx-other", "acme"}}, &1))
    # Non-owned → no DB delete attempted.
    refute called?(ctx.calls, :neon_delete_project)
  end

  test "delete_nexus releases the tenant DB when the owned nexus has one", ctx do
    # Exercise the REAL persistence path: the row carries neon_project_id (the
    # dedicated column), not a hand-injected addons field. delete reads it BEFORE
    # teardown destroys the row, then calls neon.delete_project with it.
    opts =
      base_opts(ctx,
        registry_results: %{get: {:ok, %{id: "nx-1", org_id: "acme", neon_project_id: "proj-123"}}}
      )

    assert {:ok, :torn_down} = Nexus.delete_nexus("nx-1", "acme", opts)
    assert Enum.any?(calls(ctx.calls), &match?({:teardown, {"nx-1", "acme"}}, &1))
    assert Enum.any?(calls(ctx.calls), &match?({:neon_delete_project, "proj-123"}, &1))

    # ORDER: the registry read happens BEFORE teardown (teardown destroys the row).
    seq = calls(ctx.calls) |> Enum.map(&elem(&1, 0))
    assert Enum.find_index(seq, &(&1 == :get)) < Enum.find_index(seq, &(&1 == :teardown))
  end

  test "nexus_status threads org_id and is refused for a non-owned nexus", ctx do
    opts = base_opts(ctx, status_result: {:error, :not_found})
    assert {:error, :not_found} = Nexus.nexus_status("nx-other", "acme", opts)
    assert Enum.any?(calls(ctx.calls), &match?({:status, {"nx-other", "acme"}}, &1))
  end

  test "wake_nexus threads org_id and is refused for a non-owned nexus", ctx do
    opts = base_opts(ctx, wake_result: {:error, :not_found})
    assert {:error, :not_found} = Nexus.wake_nexus("nx-other", "acme", opts)
    assert Enum.any?(calls(ctx.calls), &match?({:wake, {"nx-other", "acme"}}, &1))
  end

  test "sleep_nexus threads org_id and is refused for a non-owned nexus", ctx do
    opts = base_opts(ctx, sleep_result: {:error, :not_found})
    assert {:error, :not_found} = Nexus.sleep_nexus("nx-other", "acme", opts)
    assert Enum.any?(calls(ctx.calls), &match?({:sleep, {"nx-other", "acme"}}, &1))
  end
end
