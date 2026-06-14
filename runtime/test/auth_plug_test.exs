defmodule AuthPlugTest do
  @moduledoc """
  Tests for the shared-secret lock (WB_PUBLIC_BEARER) in Workbooks.Auth.

  Three scenarios:
    (a) WB_PUBLIC_BEARER set, no bearer → 401, no dev fallback.
    (b) WB_PUBLIC_BEARER set, correct bearer → authed with WB_TENANT (default "local").
    (c) WB_PUBLIC_BEARER unset, dev mode → x-tenant fallback still works.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  # A minimal router that just runs the Auth plug so we can inspect assigns.
  defp call(conn) do
    Workbooks.Auth.call(conn, Workbooks.Auth.init([]))
  end

  defp conn_for(path, headers \\ []) do
    c = conn(:get, path)
    Enum.reduce(headers, c, fn {k, v}, acc -> put_req_header(acc, k, v) end)
  end

  setup do
    on_exit(fn ->
      System.delete_env("WB_PUBLIC_BEARER")
      System.delete_env("WB_TENANT")
      System.delete_env("WB_TENANCY_MODE")
    end)
    :ok
  end

  # (a) Locked deploy, no bearer → 401
  test "locked deploy: no bearer returns 401" do
    System.put_env("WB_PUBLIC_BEARER", "supersecret-token-abc123")

    conn = conn_for("/api/run") |> call()

    assert conn.status == 401
    assert conn.halted
  end

  # (a) Locked deploy, wrong bearer → 401
  test "locked deploy: wrong bearer returns 401" do
    System.put_env("WB_PUBLIC_BEARER", "supersecret-token-abc123")

    conn = conn_for("/api/run", [{"authorization", "Bearer wrongtoken"}]) |> call()

    assert conn.status == 401
    assert conn.halted
  end

  # (a) Locked deploy: the x-tenant header is IGNORED — this is the invariant that
  # makes CORS '*' safe. Without it, any website (CORS *) could send
  # `x-tenant: victim` with no token and impersonate that tenant on a cloud runtime.
  test "locked deploy: x-tenant header grants NOTHING without a valid bearer (no tokenless impersonation)" do
    System.put_env("WB_PUBLIC_BEARER", "supersecret-token-abc123")

    # x-tenant alone (no bearer) → 401, never authed as the named tenant
    conn = conn_for("/api/run", [{"x-tenant", "victim-org"}]) |> call()
    assert conn.status == 401
    assert conn.halted
    refute conn.assigns[:tenant] == "victim-org"

    # x-tenant + a WRONG bearer → still 401
    conn2 =
      conn_for("/api/run", [{"x-tenant", "victim-org"}, {"authorization", "Bearer nope"}]) |> call()

    assert conn2.status == 401
    refute conn2.assigns[:tenant] == "victim-org"
  end

  # (b) Locked deploy, correct bearer → authed with default tenant "local"
  test "locked deploy: correct bearer authenticates with default tenant 'local'" do
    System.put_env("WB_PUBLIC_BEARER", "supersecret-token-abc123")
    System.delete_env("WB_TENANT")

    conn = conn_for("/api/run", [{"authorization", "Bearer supersecret-token-abc123"}]) |> call()

    refute conn.halted
    assert conn.assigns[:tenant] == "local"
    assert conn.assigns[:identity].tenant_id == "local"
  end

  # (b) Locked deploy, correct bearer → uses WB_TENANT when set
  test "locked deploy: correct bearer uses WB_TENANT when configured" do
    System.put_env("WB_PUBLIC_BEARER", "supersecret-token-abc123")
    System.put_env("WB_TENANT", "my-org")

    conn = conn_for("/api/run", [{"authorization", "Bearer supersecret-token-abc123"}]) |> call()

    refute conn.halted
    assert conn.assigns[:tenant] == "my-org"
  end

  # (c) Dev mode (no WB_PUBLIC_BEARER) → x-tenant header fallback
  test "dev mode: x-tenant header fallback when no bearer and no lock" do
    System.delete_env("WB_PUBLIC_BEARER")
    System.delete_env("WB_TENANCY_MODE")

    conn = conn_for("/api/run", [{"x-tenant", "my-tenant"}]) |> call()

    refute conn.halted
    assert conn.assigns[:tenant] == "my-tenant"
  end

  # (c) Dev mode: no header → fallback to "dev"
  test "dev mode: falls back to 'dev' tenant when no headers and no lock" do
    System.delete_env("WB_PUBLIC_BEARER")
    System.delete_env("WB_TENANCY_MODE")

    conn = conn_for("/api/run") |> call()

    refute conn.halted
    assert conn.assigns[:tenant] == "dev"
  end

  # Public paths are always open regardless of lock
  test "public path /health is always open even when locked" do
    System.put_env("WB_PUBLIC_BEARER", "supersecret-token-abc123")

    conn = conn_for("/health") |> call()

    refute conn.halted
  end

  # OIDC seam wired into the ladder (wb-wejt): when configured, a token is verified
  # by Workbooks.OIDC; an unverifiable one is rejected (fail-closed). Loopback JWKS
  # URL → NetGuard blocks it → verify fails → 401, deterministically.
  test "OIDC configured: an unverifiable token is rejected (fail-closed, no fall-through to dev)" do
    System.delete_env("WB_PUBLIC_BEARER")
    System.put_env("WB_OIDC_JWKS_URL", "http://127.0.0.1:1/jwks")
    on_exit(fn -> System.delete_env("WB_OIDC_JWKS_URL") end)

    conn = conn_for("/api/run", [{"authorization", "Bearer not.a.real.oidc.token"}]) |> call()
    assert conn.status == 401
    assert conn.halted
  end

  # And it stays inert when not configured (existing ladder unchanged).
  test "OIDC unconfigured: the branch is skipped (dev x-tenant fallback still works)" do
    System.delete_env("WB_PUBLIC_BEARER")
    System.delete_env("WB_OIDC_JWKS_URL")
    conn = conn_for("/api/run", [{"x-tenant", "t-x"}]) |> call()
    assert conn.assigns[:tenant] == "t-x"
  end

  # Multi-tenant WITHOUT a lock: isolation can never rest on a spoofable header,
  # so a credential-less request 401s rather than falling to the x-tenant dev path.
  # This is the branch that keeps a multi-tenant deploy (WB_TENANCY_MODE=multi)
  # safe even if the operator forgot to set WB_PUBLIC_BEARER (wb-oom).
  test "multi-tenant, no lock: no bearer returns 401 (NO dev fallback)" do
    System.delete_env("WB_PUBLIC_BEARER")
    System.put_env("WB_TENANCY_MODE", "multi")

    conn = conn_for("/api/run") |> call()

    assert conn.status == 401
    assert conn.halted
  end

  test "multi-tenant, no lock: x-tenant header alone grants NOTHING (no tokenless impersonation)" do
    System.delete_env("WB_PUBLIC_BEARER")
    System.put_env("WB_TENANCY_MODE", "multi")

    conn = conn_for("/api/run", [{"x-tenant", "victim-org"}]) |> call()

    assert conn.status == 401
    assert conn.halted
    refute conn.assigns[:tenant] == "victim-org"
  end

  # wb-2kt9: the reserved "*" tenant carries PLATFORM-admin rows. The x-tenant dev
  # header must NEVER be able to set the tenant to "*" (or empty/whitespace) — that
  # would make a dev/single-tenant caller owner-of-"*" (RBAC subject/2: user==tenant
  # ⇒ :owner) and let them mint a platform-admin role row. The boundary sanitizes it
  # back to the safe "dev" scope instead of honoring the sentinel.
  test "dev mode: x-tenant '*' is REJECTED — never sets the reserved platform tenant" do
    System.delete_env("WB_PUBLIC_BEARER")
    System.delete_env("WB_TENANCY_MODE")

    conn = conn_for("/api/run", [{"x-tenant", "*"}]) |> call()

    refute conn.halted
    refute conn.assigns[:tenant] == "*"
    assert conn.assigns[:tenant] == "dev"
    assert conn.assigns[:identity].tenant_id == "dev"
  end

  test "dev mode: an empty/whitespace x-tenant falls back to 'dev' (no nil/empty tenant)" do
    System.delete_env("WB_PUBLIC_BEARER")
    System.delete_env("WB_TENANCY_MODE")

    for bad <- ["", "   "] do
      conn = conn_for("/api/run", [{"x-tenant", bad}]) |> call()
      refute conn.halted
      assert conn.assigns[:tenant] == "dev"
    end
  end

  # A public/infra path (no tenant data) also routes through the dev fallback; the
  # same "*"-rejection must hold there so the :tenant assign can never be the sentinel.
  test "public path: x-tenant '*' never yields the reserved tenant assign" do
    System.delete_env("WB_PUBLIC_BEARER")
    System.delete_env("WB_TENANCY_MODE")

    conn = conn_for("/health", [{"x-tenant", "*"}]) |> call()
    refute conn.halted
    refute conn.assigns[:tenant] == "*"
  end
end
