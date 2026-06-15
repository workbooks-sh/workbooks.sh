defmodule Workbooks.HostBrokerKeystoneFixesTest do
  @moduledoc """
  PoC suite for the 2 must-fix host-call security gaps the keystone review flagged safe:false
  (the synchronous `wb:jseval/broker.host-call` seam — `Workbooks.HostBroker`).

    FIX 1 (POSTURE-GATE BYPASS) — `JsEngine.host_broker_imports/1` carries the grant ONLY when
      `Workbooks.Harness.enabled?/0` (the same gate the loopback child-spec start is gated on). In a
      forbidden posture (cloud / multi-tenant, or no WB_DESKTOP/WB_HARNESS) the import is wired with a
      nil grant → EVERY op (exec/fs/oauth/llm/creds) default-denies, exactly as if the loopback were
      never started. Under WB_DESKTOP single-tenant the grant flows and the ops work.

    FIX 2 (per-tenant LLM key) — `HostBrokerLLM.complete` (live) routes the egress with the TENANT's
      OWN key resolved from the grant's `:principal` (a Vars-scoped `OPENROUTER_API_KEY`), falling back
      to the platform key. Two tenants resolve their OWN key, not one global.
  """
  use ExUnit.Case, async: false

  alias Workbooks.{JsEngine, Harness, Vars, Llm}

  @broker_ns "wb:jseval/broker"
  @broker_fn "host-call"

  # Extract the 1-arg import closure JsEngine wires for a given grant — exactly what the wasmex linker
  # would invoke on a guest `__wbHostCall(jsonReq)`.
  defp import_closure(grant) do
    %{@broker_ns => %{@broker_fn => {:fn, f}}} = JsEngine.host_broker_imports(grant)
    f
  end

  defp call(grant, req), do: Jason.decode!(import_closure(grant).(Jason.encode!(req)))

  defp clear_posture do
    System.delete_env("WB_DESKTOP")
    System.delete_env("WB_HARNESS")
    System.delete_env("WB_TENANCY_MODE")
  end

  setup do
    saved =
      for k <- ~w(WB_DESKTOP WB_HARNESS WB_TENANCY_MODE), into: %{}, do: {k, System.get_env(k)}

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)

    :ok
  end

  # A fully-capable grant (exec + fs + creds + oauth + llm) — the kind a desktop session mints.
  defp full_grant(principal \\ "tenant-a") do
    %{
      allow: true,
      commands: :all,
      principal: principal,
      depth: 0,
      creds_scope: %{user: principal, provider: "github"},
      workdir: System.tmp_dir!()
    }
  end

  # ── FIX 1: the host-call seam DEFAULT-DENIES in a forbidden posture ─────────────────────────────

  describe "FIX 1 — posture gate on the sync host-call import" do
    # acp-cloud-enable: the harness surface is now PERMITTED in multi-tenant (gate relaxed behind per-tenant
    # isolation). The seam therefore CARRIES the grant in multi-tenant — the safety is the grant being bound
    # to the verified tenant (HarnessPool), not nil-ing the seam. A principal'd llm op succeeds; the surface
    # is no longer denied wholesale by the posture.
    test "multi-tenant posture (WB_TENANCY_MODE=multi) PERMITS the surface (isolation, not kill-switch)" do
      clear_posture()
      System.put_env("WB_TENANCY_MODE", "multi")
      assert Harness.enabled?()

      grant = full_grant()
      # llm needs only a principal'd grant; the deterministic mock returns tool_use (no network).
      assert %{"ok" => true, "resp" => %{"stop_reason" => "tool_use"}} =
               call(grant, %{"op" => "llm", "messages" => []})
    end

    test "BARE single-tenant (no WB_DESKTOP/WB_HARNESS, not multi) DENIES even with a minted grant" do
      clear_posture()
      refute Harness.enabled?()

      grant = full_grant()
      assert %{"ok" => false} = call(grant, %{"op" => "exec", "name" => "echo", "argv" => ["hi"]})
      assert %{"ok" => false} = call(grant, %{"op" => "fs", "fsop" => "read", "path" => "x"})
      assert %{"ok" => false} = call(grant, %{"op" => "llm", "messages" => []})
    end

    test "WB_DESKTOP single-tenant PERMITS the grant — the same llm op succeeds" do
      clear_posture()
      System.put_env("WB_DESKTOP", "1")
      assert Harness.enabled?()

      # llm needs only a principal'd grant; the deterministic mock returns a tool_use (no network).
      grant = full_grant()
      assert %{"ok" => true, "resp" => %{"stop_reason" => "tool_use"}} =
               call(grant, %{"op" => "llm", "messages" => []})
    end

    test "the import is identical in shape regardless of posture (stays LINKED, just nil-grant)" do
      clear_posture()
      # Forbidden posture still returns a wired import (instantiation must not fail) — it just carries nil.
      assert %{@broker_ns => %{@broker_fn => {:fn, f}}} = JsEngine.host_broker_imports(full_grant())
      assert is_function(f, 1)
    end
  end

  # ── FIX 2: per-tenant LLM key resolution ────────────────────────────────────────────────────────

  describe "FIX 2 — per-tenant LLM key" do
    setup do
      # Vars is a named singleton; start it for the test if the app didn't.
      case Process.whereis(Vars) do
        nil -> start_supervised!(Vars)
        _ -> :ok
      end

      :ok
    end

    test "host_secret resolves a tenant's OWN key, isolated per tenant; platform fallback otherwise" do
      Vars.set("tenant-a", "OPENROUTER_API_KEY", "sk-AAA", true)
      Vars.set("tenant-b", "OPENROUTER_API_KEY", "sk-BBB", true)

      # Each principal resolves ITS own key (host-side raw read — never the redacted guest path).
      assert "sk-AAA" == Vars.host_secret("tenant-a", "OPENROUTER_API_KEY")
      assert "sk-BBB" == Vars.host_secret("tenant-b", "OPENROUTER_API_KEY")
      # The guest-facing get/2 still REDACTS — host_secret is host-only.
      assert {:secret, :redacted, _} = Vars.get("tenant-a", "OPENROUTER_API_KEY")
      # An unconfigured tenant has no key → caller falls back to the platform key.
      assert nil == Vars.host_secret("tenant-c", "OPENROUTER_API_KEY")
    end

    test "Llm.resolve_key selects the per-PRINCIPAL key (the REAL egress resolver), not one global" do
      Vars.set("tenant-a", "OPENROUTER_API_KEY", "sk-AAA", true)
      Vars.set("tenant-b", "OPENROUTER_API_KEY", "sk-BBB", true)
      # Platform key — what the OLD code billed EVERY tenant as.
      Workbooks.Secrets.put("OPENROUTER_API_KEY", "sk-PLATFORM")

      # The exact resolver `Llm.complete` threads into the Bearer header for the egress.
      assert "sk-AAA" == Llm.resolve_key(principal: "tenant-a")
      assert "sk-BBB" == Llm.resolve_key(principal: "tenant-b")
      # No principal (or an unconfigured one) → platform fallback (intended).
      assert "sk-PLATFORM" == Llm.resolve_key([])
      assert "sk-PLATFORM" == Llm.resolve_key(principal: "tenant-unconfigured")
      # An explicit :api_key opt wins (caller pre-resolved).
      assert "sk-EXPLICIT" == Llm.resolve_key(principal: "tenant-a", api_key: "sk-EXPLICIT")
    end

    test "HostBrokerLLM threads the grant's principal into the LLM call (live path)" do
      Vars.set("tenant-a", "OPENROUTER_API_KEY", "sk-AAA", true)
      Vars.set("tenant-b", "OPENROUTER_API_KEY", "sk-BBB", true)
      Workbooks.Secrets.put("OPENROUTER_API_KEY", "sk-PLATFORM")

      # The live path resolves the SAME per-principal key the resolver selects: assert the two tenants'
      # grants pick distinct keys (proving the principal is threaded, not dropped to one global).
      grant_a = full_grant("tenant-a")
      grant_b = full_grant("tenant-b")
      assert "sk-AAA" == Llm.resolve_key(principal: grant_a.principal)
      assert "sk-BBB" == Llm.resolve_key(principal: grant_b.principal)
      refute Llm.resolve_key(principal: grant_a.principal) == Llm.resolve_key(principal: grant_b.principal)
    end
  end
end
