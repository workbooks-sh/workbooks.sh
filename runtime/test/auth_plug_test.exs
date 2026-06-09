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
end
