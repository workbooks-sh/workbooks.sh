defmodule Nexus.Auth.TokenTest do
  use ExUnit.Case, async: false
  alias Nexus.Auth.Token
  import Plug.Test

  # The token store is durable DETS that PERSISTS ACROSS test-suite runs. `System.unique_integer`
  # resets per VM, so a bare counter collides with a prior run's org and leaks its tokens (the
  # flaky `["a", "token"]`, wb-bgod). Mix in `os_time` for GLOBAL uniqueness, and revoke this test's
  # tokens on exit so the DETS file doesn't accumulate — mirrors cp_token_test's cleanup.
  defp org do
    o = "org_#{System.os_time(:nanosecond)}_#{System.unique_integer([:positive])}"
    on_exit(fn -> for t <- Token.list(o), do: Token.revoke(o, t.id) end)
    o
  end

  test "mint → verify round-trips tenant + roles + scopes" do
    t_org = org()
    %{token: t, id: id} = Token.mint(t_org, name: "ci", scopes: ["read", "write"], roles: ["admin"])
    assert String.starts_with?(t, "wbk_")
    assert {:ok, identity} = Token.verify(t)
    assert identity.tenant == t_org
    assert identity.scopes == ["read", "write"]
    assert identity.roles == ["admin"]
    assert identity.user == id
  end

  test "SECURITY: the plaintext is never stored — only its hash" do
    t_org = org()
    %{token: t} = Token.mint(t_org)
    [rec] = Token.list(t_org)
    refute Enum.any?(Map.values(rec), &(&1 == t))
    refute Map.has_key?(rec, :tenant)
  end

  test "revoke makes a token stop verifying (idempotent)" do
    t_org = org()
    %{token: t, id: id} = Token.mint(t_org)
    assert {:ok, _} = Token.verify(t)
    assert :ok = Token.revoke(t_org, id)
    assert Token.verify(t) == :error
    assert :ok = Token.revoke(t_org, id)
  end

  test "unknown / non-wbk tokens are rejected" do
    assert Token.verify("wbk_nonexistent") == :error
    assert Token.verify("not-a-token") == :error
    assert Token.verify(nil) == :error
  end

  test "list is tenant-scoped + metadata-only" do
    a = org()
    b = org()
    Token.mint(a, name: "a")
    Token.mint(b, name: "b")
    names = Token.list(a) |> Enum.map(& &1.name)
    assert names == ["a"]
  end

  test "TokenBearer adapter authenticates a Bearer token to the full identity" do
    t_org = org()
    %{token: t} = Token.mint(t_org, scopes: ["api"])
    conn = conn(:get, "/") |> Plug.Conn.put_req_header("authorization", "Bearer " <> t)
    assert {:ok, id} = Nexus.Auth.TokenBearer.authenticate(conn)
    assert id.tenant == t_org
    assert id.scopes == ["api"]
    assert {:error, _} = Nexus.Auth.TokenBearer.authenticate(conn(:get, "/"))
  end
end
