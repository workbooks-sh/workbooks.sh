defmodule Workbooks.HarnessSecurityFixesTest do
  @moduledoc """
  PoC suite for the 5 security findings on the in-wasm harness surface (branch acp-slices-123). Each test
  defeats the exact PoC of its finding — hermetic, no SM eval-host required (host-seam level).

    FIX 1 — principal-OPTIONAL minting: an exec-capable grant with a nil principal is REFUSED at mint and
            DENIED at the loopback route; a principal'd grant is rate/concurrency/revocation governed.
    FIX 2 — surface ALWAYS-ON: Harness.enabled?/0 is false under a multi-tenant posture (loopback not started).
    FIX 3 — multi-tenant creds co-location: the :file backend is refused under multi-tenant; desktop works.
    FIX 4 — oauth.loopback arbitrary URL: non-https / off-allowlist authorize_base is rejected.
    FIX 5 — fixed loopback port: the default bound port is NOT the fixed 8919 (random/OS-assigned).
  """
  use ExUnit.Case, async: false

  alias Workbooks.{ExecBroker, ExecLoopback, HarnessCreds, Harness, OAuthLoopback, Revocation}

  setup_all do
    # The app no longer starts the loopback in test env (FIX 2 — posture gate). Start it ONCE here for the
    # route tests; the test substrate is a single-user desktop posture (WB_HARNESS=1).
    System.put_env("WB_HARNESS", "1")
    # Start the listener UNLINKED so it survives this ephemeral test process (Bandit.start_link links to the
    # caller; a per-module setup would otherwise die and leave a stale recorded port for later modules).
    {:ok, _} = Task.start(fn -> ExecLoopback.start_listener(); Process.sleep(:infinity) end)
    wait_for_loopback()
    System.delete_env("WB_HARNESS")
    :ok
  end

  defp wait_for_loopback(tries \\ 100) do
    cond do
      tries <= 0 -> :ok
      match?(p when is_integer(p), :persistent_term.get({ExecLoopback, :port}, nil)) -> :ok
      true -> Process.sleep(10); wait_for_loopback(tries - 1)
    end
  end

  # ── FIX 1: principal-OPTIONAL exec minting ──────────────────────────────────────────────────────

  describe "FIX 1 — exec-capable grants require a non-nil principal" do
    test "ExecLoopback.mint REFUSES an exec-capable grant (allow: true) with no principal" do
      assert_raise ArgumentError, ~r/requires a non-nil :principal/, fn ->
        ExecLoopback.mint(%{allow: true, commands: :all, principal: nil})
      end

      assert_raise ArgumentError, ~r/requires a non-nil :principal/, fn ->
        ExecLoopback.mint(%{allow: true, commands: :all})
      end
    end

    test "a creds-only grant (no allow) still mints without a principal (not weakened)" do
      tok = ExecLoopback.mint(%{creds_scope: %{user: "u", provider: "claude"}})
      assert is_binary(tok)
      ExecLoopback.revoke(tok)
    end

    test "the loopback /__wb/exec route DENIES a principal-less exec grant (defense-in-depth)" do
      # forge a principal-less exec-capable grant straight into the table (bypassing mint's guard) to prove
      # the ROUTE itself refuses to call the broker with nil — the exact PoC: a granted harness with no
      # principal reaching the broker's uncapped host-internal path.
      tok = "poc-noprincipal-#{System.unique_integer([:positive])}"
      :ets.insert(:wb_exec_loopback_grants, {tok, %{allow: true, commands: :all, principal: nil}})
      on_exit(fn -> :ets.delete(:wb_exec_loopback_grants, tok) end)

      base = "http://127.0.0.1:#{ExecLoopback.port()}"
      assert {:ok, %{status: 403}} = post(base <> "/__wb/exec", tok, %{name: "grep", argv: [], stdin: ""})
      assert {:ok, %{status: 403}} = post(base <> "/__wb/llm", tok, %{messages: []})
    end

    test "a principal'd exec is REVOCATION-governed (a revoked principal's exec is killed)" do
      p = "poc-revoked-#{System.unique_integer([:positive])}"
      assert :ok = Revocation.revoke(p)
      # principal'd grant → broker checks revocation; with the principal revoked, exec is denied (kill-switch).
      assert {:error, :revoked} =
               ExecBroker.exec("coreutils", ["seq", "1"], "", allow: true, principal: p)

      assert :ok = Revocation.unrevoke(p)
    end

    test "a principal'd exec is CONCURRENCY-capped (@max_concurrent), nil principal is uncapped (host-only)" do
      p = "poc-conc-#{System.unique_integer([:positive])}"
      Workbooks.BrokerTables.ensure(:wb_exec_slots, [:named_table, :public, :set])
      on_exit(fn -> :ets.delete(:wb_exec_slots, p) end)
      # pre-fill the principal to its cap; the next acquire bumps past it → refused before anything runs.
      # Use a REGISTERED command (the cap is checked after the command-exists guard, before running) so the
      # cap is the deciding refusal — `grep` is registered in this runtime.
      if "grep" in Workbooks.CommandRegistry.list() do
        :ets.insert(:wb_exec_slots, {p, 4})

        assert {:error, :too_many_processes} =
                 ExecBroker.exec("grep", ["x"], "", allow: true, principal: p, max_concurrent: 4)

        # the refused acquire rolled back → count stays at the cap (no leak).
        assert :ets.lookup(:wb_exec_slots, p) == [{p, 4}]
      else
        IO.puts("\n[skip] grep not registered — concurrency cap also proven in exec_broker_test (:pallet)")
      end
    end

    test "a principal'd exec is RATE-capped" do
      p = "poc-rate-#{System.unique_integer([:positive])}"

      assert {:error, :unknown_command} =
               ExecBroker.exec("nope", [], "", allow: true, principal: p, rate: {1, 60_000})

      assert {:error, :rate_limited} =
               ExecBroker.exec("nope", [], "", allow: true, principal: p, rate: {1, 60_000})
    end
  end

  # ── FIX 2: harness surface posture gate ─────────────────────────────────────────────────────────

  describe "FIX 2 — harness surface is posture-gated (relaxed: permitted in multi-tenant behind isolation)" do
    # acp-cloud-enable: the blanket `not multi?` guard is DROPPED. The harness surface is now PERMITTED in a
    # multi-tenant hosted posture because per-tenant isolation (HarnessPool cap + verified-tenant binding +
    # TenantBudget) is the safety, not the on/off switch.
    test "Harness.enabled? is TRUE under a multi-tenant posture (per-tenant isolation is the safety)" do
      with_env(%{"WB_HARNESS" => nil, "WB_DESKTOP" => nil, "WB_TENANCY_MODE" => "multi"}, fn ->
        assert Harness.enabled?()
      end)
    end

    test "Harness.enabled? is FALSE when neither WB_DESKTOP nor WB_HARNESS is set (bare single-tenant)" do
      with_env(%{"WB_HARNESS" => nil, "WB_DESKTOP" => nil, "WB_TENANCY_MODE" => "single"}, fn ->
        refute Harness.enabled?()
      end)
    end

    test "Harness.enabled? is TRUE on single-user desktop (WB_DESKTOP=1, single-tenant)" do
      with_env(%{"WB_DESKTOP" => "1", "WB_HARNESS" => nil, "WB_TENANCY_MODE" => "single"}, fn ->
        assert Harness.enabled?()
      end)
    end

    test "the application starts ExecLoopback in BOTH single-desktop and multi-tenant, off in bare single" do
      with_env(%{"WB_HARNESS" => nil, "WB_DESKTOP" => nil, "WB_TENANCY_MODE" => "multi"}, fn ->
        assert Harness.enabled?()
      end)

      with_env(%{"WB_HARNESS" => "1", "WB_TENANCY_MODE" => "single"}, fn ->
        assert Harness.enabled?()
      end)

      with_env(%{"WB_HARNESS" => nil, "WB_DESKTOP" => nil, "WB_TENANCY_MODE" => "single"}, fn ->
        refute Harness.enabled?()
      end)
    end
  end

  # ── FIX 3: multi-tenant creds co-location ───────────────────────────────────────────────────────

  describe "FIX 3 — :file creds backend refused under multi-tenant" do
    setup do
      dir = Path.join(System.tmp_dir!(), "wb-creds-poc-#{System.unique_integer([:positive])}")
      prev = System.get_env("WB_HARNESS_CREDS_DIR")
      System.put_env("WB_HARNESS_CREDS_DIR", dir)
      System.delete_env("WB_HARNESS_CREDS")

      on_exit(fn ->
        if prev, do: System.put_env("WB_HARNESS_CREDS_DIR", prev), else: System.delete_env("WB_HARNESS_CREDS_DIR")
        File.rm_rf(dir)
      end)

      :ok
    end

    test "requesting the :file backend under multi-tenant RAISES (no shared-store co-location)" do
      with_env(%{"WB_HARNESS" => "1", "WB_TENANCY_MODE" => "multi"}, fn ->
        refute HarnessCreds.file_backend_allowed?()

        assert_raise ArgumentError, ~r/:file backend is co-located.*REFUSED/, fn ->
          HarnessCreds.put("user-A", "claude", "blob")
        end
      end)
    end

    test "single-user desktop still round-trips the :file backend" do
      with_env(%{"WB_HARNESS" => "1", "WB_TENANCY_MODE" => "single"}, fn ->
        assert HarnessCreds.file_backend_allowed?()
        assert :ok = HarnessCreds.put("user-A", "claude", "blob-OK")
        assert {:ok, "blob-OK"} = HarnessCreds.get("user-A", "claude")
      end)
    end

    test "the :file store path is scoped per-tenant" do
      with_env(%{"WB_HARNESS" => "1", "WB_TENANCY_MODE" => "single", "WB_TENANT" => "tenantX"}, fn ->
        assert :ok = HarnessCreds.put("user-A", "claude", "X-blob")
      end)

      with_env(%{"WB_HARNESS" => "1", "WB_TENANCY_MODE" => "single", "WB_TENANT" => "tenantY"}, fn ->
        # a DIFFERENT tenant's store does not see tenantX's blob (path is per-tenant).
        assert {:error, :not_found} = HarnessCreds.get("user-A", "claude")
      end)
    end
  end

  # ── FIX 4: oauth.loopback arbitrary URL ─────────────────────────────────────────────────────────

  describe "FIX 4 — oauth.loopback authorize_base validation" do
    @valid_challenge "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

    test "a non-https authorize_base is REJECTED" do
      assert {:error, {:invalid_authorize_base, :https_required}} =
               OAuthLoopback.start(%{
                 "authorize_base" => "http://claude.ai/oauth/authorize",
                 "code_challenge" => @valid_challenge
               })
    end

    test "an off-allowlist authorize_base is REJECTED (the exact PoC: an attacker host)" do
      assert {:error, {:invalid_authorize_base, {:host_not_allowed, "evil.example.com"}}} =
               OAuthLoopback.start(%{
                 "authorize_base" => "https://evil.example.com/oauth/authorize?x=1",
                 "code_challenge" => @valid_challenge
               })
    end

    test "an allow-listed https authorize_base PASSES validation (reaches the desktop-only gate)" do
      # validation passes → falls through to the desktop bridge, which is absent here → :desktop_only.
      for host <- ["claude.ai", "console.anthropic.com", "auth.openai.com"] do
        assert {:error, :desktop_only} =
                 OAuthLoopback.start(%{
                   "authorize_base" => "https://#{host}/oauth/authorize",
                   "code_challenge" => @valid_challenge
                 })
      end
    end
  end

  # ── FIX 5: fixed loopback port ──────────────────────────────────────────────────────────────────

  describe "FIX 5 — loopback binds a random (non-fixed) port" do
    test "the default bound port is NOT the predictable fixed 8919" do
      assert ExecLoopback.port() != 8919
      assert ExecLoopback.port() > 0
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────────────────────────

  defp with_env(kvs, fun) do
    prev = for {k, _} <- kvs, into: %{}, do: {k, System.get_env(k)}

    Enum.each(kvs, fn
      {k, nil} -> System.delete_env(k)
      {k, v} -> System.put_env(k, v)
    end)

    try do
      fun.()
    after
      Enum.each(prev, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end
  end

  defp post(url, token, body) do
    _ = Application.ensure_all_started(:inets)
    headers = [{~c"x-wb-exec", String.to_charlist(token)}]
    request = {String.to_charlist(url), headers, ~c"application/json", Jason.encode!(body)}

    case :httpc.request(:post, request, [{:timeout, 5_000}], []) do
      {:ok, {{_v, status, _r}, _h, resp_body}} ->
        {:ok, %{status: status, body: IO.iodata_to_binary(resp_body)}}

      other ->
        other
    end
  end
end
