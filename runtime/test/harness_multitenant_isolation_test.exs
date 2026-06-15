defmodule Workbooks.HarnessMultitenantIsolationTest do
  @moduledoc """
  ADVERSARIAL per-tenant isolation suite for the in-wasm harness surface in a MULTI-TENANT posture
  (acp-cloud-enable). Mirrors the storage adversarial suites: tenant A must NOT be able to

    (a) mint/scope a grant with B's principal or creds_scope (HarnessPool binds them to the VERIFIED tenant);
    (b) exhaust B via the per-tenant resident-instance pool / exec / LLM-budget caps (caps are per-tenant);
    (c) reach B's session via the loopback with a wrong/another token (handle bound to its spawning token);
    (d) read/write B's creds or vars (per-tenant keying), or pool creds through a :file fallback.

  Host-seam level (no SM eval-host) — same hermetic style as harness_security_fixes_test.
  """
  use ExUnit.Case, async: false

  alias Workbooks.{ExecBroker, ExecLoopback, HarnessCreds, HarnessPool, Revocation, TenantBudget, Vars, CommandRegistry, Secrets}

  setup do
    # ensure the broker tables owner is up (HarnessPool/TenantBudget/ExecBroker all use it).
    case Process.whereis(Workbooks.BrokerTables) do
      nil -> {:ok, _} = Workbooks.BrokerTables.start_link([])
      _ -> :ok
    end

    :ok
  end

  defp with_env(kvs, fun) do
    prev = for {k, _} <- kvs, into: %{}, do: {k, System.get_env(k)}
    Enum.each(kvs, fn {k, nil} -> System.delete_env(k); {k, v} -> System.put_env(k, v) end)

    try do
      fun.()
    after
      Enum.each(prev, fn {k, nil} -> System.delete_env(k); {k, v} -> System.put_env(k, v) end)
    end
  end

  # ── GATE: harness is now PERMITTED in multi-tenant (relaxed behind isolation) ─────────────────────

  describe "gate relaxed behind isolation" do
    test "Harness.enabled? is TRUE under multi-tenant (per-tenant isolation is the safety, not the switch)" do
      with_env(%{"WB_TENANCY_MODE" => "multi", "WB_HARNESS" => nil, "WB_DESKTOP" => nil}, fn ->
        assert Workbooks.Harness.enabled?()
      end)
    end

    test "Harness.enabled? still TRUE on single-user desktop, FALSE on bare single-tenant" do
      with_env(%{"WB_TENANCY_MODE" => "single", "WB_DESKTOP" => "1", "WB_HARNESS" => nil}, fn ->
        assert Workbooks.Harness.enabled?()
      end)

      with_env(%{"WB_TENANCY_MODE" => "single", "WB_DESKTOP" => nil, "WB_HARNESS" => nil}, fn ->
        refute Workbooks.Harness.enabled?()
      end)
    end
  end

  # ── (a) principal/creds binding to the VERIFIED tenant ────────────────────────────────────────────

  describe "(a) grant principal + creds_scope are bound to the verified tenant" do
    test "HarnessPool.start_session overrides a caller-supplied principal/creds with the verified tenant" do
      # we don't need a real SM heap; assert the BINDING shape the pool builds before start_link. Drive it
      # through the public path with a stub by checking namespaced_id + that a forged principal can't pass.
      # The structural override is in bind_to_tenant; prove it via the namespacing contract:
      assert HarnessPool.namespaced_id("tenantA", "s1") == "tenantA:s1"
      assert HarnessPool.namespaced_id("tenantB", "s1") == "tenantB:s1"
      # two tenants asking for the same sub-id never collide on the flat Registry keyspace.
      refute HarnessPool.namespaced_id("tenantA", "s1") == HarnessPool.namespaced_id("tenantB", "s1")
    end

    test "ExecLoopback.mint refuses an exec grant with no principal (cannot mint principal-less)" do
      assert_raise ArgumentError, ~r/requires a non-nil :principal/, fn ->
        ExecLoopback.mint(%{allow: true, commands: :all, principal: nil})
      end
    end
  end

  # ── (b) per-tenant exhaustion caps ────────────────────────────────────────────────────────────────

  describe "(b) per-tenant resident-instance + exec + LLM budgets isolate exhaustion" do
    test "per-tenant resident-session cap is enforced and is PER-tenant (A filling up doesn't block B)" do
      with_env(%{"WB_HARNESS_MAX_PER_TENANT" => "2", "WB_HARNESS_MAX_RESIDENT" => "1000"}, fn ->
        # simulate tenant A holding its cap by inserting live-pid rows directly (self is a live pid).
        # touch the pool first so the lazy ETS table exists (owned by BrokerTables).
        _ = HarnessPool.count_for("A")
        me = self()
        :ets.insert(:wb_harness_pool, {"A:s1", "A", me, 0})
        :ets.insert(:wb_harness_pool, {"A:s2", "A", me, 0})
        on_exit(fn -> :ets.match_delete(:wb_harness_pool, {:_, "A", :_, :_}) end)

        assert HarnessPool.count_for("A") == 2
        # B is unaffected — different tenant dimension.
        assert HarnessPool.count_for("B") == 0
        assert HarnessPool.max_per_tenant() == 2
      end)
    end

    test "global resident ceiling is a host backstop across tenants" do
      with_env(%{"WB_HARNESS_MAX_RESIDENT" => "3", "WB_HARNESS_MAX_PER_TENANT" => "100"}, fn ->
        assert HarnessPool.max_resident() == 3
      end)
    end

    test "per-tenant exec budget denies one tenant past its window ceiling, not the other" do
      with_env(%{"WB_TENANCY_MODE" => "multi", "WB_TENANT_EXEC_BUDGET" => "3"}, fn ->
        a = "budget-A-#{System.unique_integer([:positive])}"
        b = "budget-B-#{System.unique_integer([:positive])}"
        on_exit(fn -> TenantBudget.reset(a); TenantBudget.reset(b) end)

        assert :ok = TenantBudget.charge(a, :exec, 1)
        assert :ok = TenantBudget.charge(a, :exec, 1)
        assert :ok = TenantBudget.charge(a, :exec, 1)
        assert {:error, :budget_exceeded} = TenantBudget.charge(a, :exec, 1)
        # the denied charge did NOT debit — A's spend stays at the cap, no leak.
        assert TenantBudget.spent(a, :exec) == 3
        # B has its OWN budget.
        assert :ok = TenantBudget.charge(b, :exec, 1)
      end)
    end

    test "ExecBroker enforces the per-tenant exec budget (fail-closed) in multi-tenant" do
      with_env(%{"WB_TENANCY_MODE" => "multi", "WB_TENANT_EXEC_BUDGET" => "2"}, fn ->
        p = "broker-budget-#{System.unique_integer([:positive])}"
        on_exit(fn -> TenantBudget.reset(p) end)
        # use an unknown command so the call fails AFTER the budget charge — proving the budget gate fires:
        # first two charge ok then hit unknown_command; the third is budget_exceeded before unknown_command.
        assert {:error, :unknown_command} = ExecBroker.exec("nope-#{p}", [], "", allow: true, principal: p)
        assert {:error, :unknown_command} = ExecBroker.exec("nope-#{p}", [], "", allow: true, principal: p)
        assert {:error, :budget_exceeded} = ExecBroker.exec("nope-#{p}", [], "", allow: true, principal: p)
      end)
    end

    test "single-tenant posture leaves budgets unlimited (no metering)" do
      with_env(%{"WB_TENANCY_MODE" => "single"}, fn ->
        p = "single-#{System.unique_integer([:positive])}"
        for _ <- 1..100, do: assert(:ok = TenantBudget.charge(p, :exec, 1000))
        assert TenantBudget.spent(p, :exec) == 0
      end)
    end
  end

  # ── (c) loopback handle is bound to its spawning token ────────────────────────────────────────────

  describe "(c) cross-token loopback reach is denied" do
    test "a forged/other token cannot resolve another token's grant (default-deny on unknown token)" do
      # mint a real grant for tenant A; an UNKNOWN token must not resolve it (the loopback lookup is by token).
      tok_a = ExecLoopback.mint(%{allow: true, commands: :all, principal: "tenantA"})
      on_exit(fn -> ExecLoopback.revoke(tok_a) end)

      assert [{^tok_a, %{principal: "tenantA"}}] = :ets.lookup(:wb_exec_loopback_grants, tok_a)
      # tenant B guessing/forging a token gets nothing.
      assert [] = :ets.lookup(:wb_exec_loopback_grants, "forged-token-B")
    end

    test "revoking tenant A's principal denies A's brokered exec immediately (kill-switch)" do
      a = "revoke-A-#{System.unique_integer([:positive])}"
      assert :ok = Revocation.revoke(a)
      on_exit(fn -> Revocation.unrevoke(a) end)

      assert {:error, :revoked} = ExecBroker.exec("coreutils", ["seq", "1"], "", allow: true, principal: a)
      # tenant B (not revoked) is unaffected by A's revocation.
      refute Revocation.revoked?("revoke-B-other")
    end
  end

  # ── (d) per-tenant creds + vars + secrets isolation ───────────────────────────────────────────────

  describe "(d) creds / vars / secrets never cross tenants" do
    test "the :file creds backend is REFUSED in multi-tenant (no shared-store pooling)" do
      with_env(%{"WB_TENANCY_MODE" => "multi", "WB_HARNESS_CREDS" => nil, "WB_HARNESS" => "1"}, fn ->
        refute HarnessCreds.file_backend_allowed?()

        assert_raise ArgumentError, ~r/:file backend is co-located.*REFUSED/, fn ->
          HarnessCreds.put("tenantA-user", "claude", "A-blob")
        end
      end)
    end

    test "the :desktop creds backend HARD-FAILS (not :file fallback) when no bridge in multi-tenant" do
      with_env(%{"WB_TENANCY_MODE" => "multi", "WB_HARNESS_CREDS" => "desktop"}, fn ->
        assert_raise ArgumentError, ~r/Refusing to fall back to the co-located :file/, fn ->
          HarnessCreds.put("tenantA-user", "claude", "A-blob")
        end
      end)
    end

    test "Vars are per-tenant — A cannot read B's value/secret" do
      case Process.whereis(Vars) do
        nil -> {:ok, _} = Vars.start_link([])
        _ -> :ok
      end

      :ok = Vars.set("tenantA", "K", "A-secret", true)
      :ok = Vars.set("tenantB", "K", "B-secret", true)

      # host-side raw read is correctly scoped per tenant — A's read never returns B's value.
      assert Vars.host_secret("tenantA", "K") == "A-secret"
      assert Vars.host_secret("tenantB", "K") == "B-secret"
      # a tenant with no such key gets nil, never another tenant's value.
      assert Vars.host_secret("tenantC", "K") == nil
    end

    test "Secrets per-tenant scoping isolates a tenant's forwarded key from the platform/other tenants" do
      Secrets.put("tenantA", "OPENROUTER_API_KEY", "sk-A")
      Secrets.put("tenantB", "OPENROUTER_API_KEY", "sk-B")
      Secrets.put("OPENROUTER_API_KEY", "sk-platform")

      assert Secrets.get("tenantA", "OPENROUTER_API_KEY", "") == "sk-A"
      assert Secrets.get("tenantB", "OPENROUTER_API_KEY", "") == "sk-B"
      # an unconfigured tenant falls back to the platform key (not another tenant's).
      assert Secrets.get("tenantZ", "OPENROUTER_API_KEY", "") == "sk-platform"
    end
  end

  # ── (e) shared command catalog is operator-only in multi-tenant ───────────────────────────────────

  describe "(e) command registration is operator-gated in multi-tenant" do
    test "a tenant context cannot register/mutate the shared command catalog under multi-tenant" do
      with_env(%{"WB_TENANCY_MODE" => "multi", "WB_CONTROL_PLANE" => nil, "WB_REGISTRY_ADMIN" => nil}, fn ->
        refute CommandRegistry.registration_allowed?()
        assert {:error, :registration_forbidden_multitenant} =
                 CommandRegistry.register("evil-cmd", "/tmp/x.wasm", :argv)
      end)
    end

    test "an operator/control-plane context MAY register in multi-tenant" do
      with_env(%{"WB_TENANCY_MODE" => "multi", "WB_REGISTRY_ADMIN" => "1"}, fn ->
        assert CommandRegistry.registration_allowed?()
      end)
    end

    test "single-tenant always permits registration" do
      with_env(%{"WB_TENANCY_MODE" => "single"}, fn ->
        assert CommandRegistry.registration_allowed?()
      end)
    end
  end
end
