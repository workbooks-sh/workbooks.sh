defmodule Nexus.ControlPlane.TokenTest do
  use ExUnit.Case, async: false
  alias Nexus.ControlPlane.Token

  @org "org_test_#{System.unique_integer([:positive])}"

  setup do
    on_exit(fn -> for t <- Token.list(@org), do: Token.revoke(@org, t.id) end)
    :ok
  end

  test "mint → resolve → org; plaintext shown once, never stored in clear" do
    %{token: tok, id: id} = Token.mint(@org, "my-laptop")
    assert String.starts_with?(tok, "wbk_")
    # Default authority is `member` (older callers), user nil.
    assert {:ok, %{org: @org, role: "member", user: nil}} = Token.resolve(tok)

    listed = Token.list(@org)
    row = Enum.find(listed, &(&1.id == id))
    assert row.name == "my-laptop"
    refute Map.has_key?(row, :token)
    refute Map.has_key?(row, :org)
  end

  test "a PAT inherits the minting user's role + id" do
    %{token: tok} = Token.mint(@org, "my-laptop", role: "admin", user: "u_42")
    assert {:ok, %{org: @org, role: "admin", user: "u_42"}} = Token.resolve(tok)

    # And the Cloud adapter surfaces that authority as the request identity.
    conn = Plug.Test.conn(:get, "/") |> Plug.Conn.put_req_header("authorization", "Bearer #{tok}")
    assert {:ok, %{tenant: @org, user: "u_42", roles: ["admin"]}} = Nexus.Auth.Cloud.authenticate(conn)
  end

  test "unknown / non-PAT tokens don't resolve" do
    assert :error = Token.resolve("wbk_nope")
    assert :error = Token.resolve("Bearer something")
    assert :error = Token.resolve("")
  end

  test "revoke kills the token" do
    %{token: tok, id: id} = Token.mint(@org, "ci")
    assert {:ok, %{org: @org}} = Token.resolve(tok)
    Token.revoke(@org, id)
    assert :error = Token.resolve(tok)
  end

  test "Cloud adapter: a PAT authenticates to its org; junk is rejected on the gated API" do
    %{token: tok} = Token.mint(@org, "cli")

    pat_conn = Plug.Test.conn(:get, "/") |> Plug.Conn.put_req_header("authorization", "Bearer #{tok}")
    assert {:ok, %{tenant: @org, user: "cli", roles: ["member"]}} = Nexus.Auth.Cloud.authenticate(pat_conn)

    # A non-PAT bearer is not a credential we issue: rejected on the gated /api/platform surface,
    # but public surfaces stay open as the default tenant (one nexus = site + control plane).
    junk = fn path -> Plug.Test.conn(:get, path) |> Plug.Conn.put_req_header("authorization", "Bearer not-a-pat") end
    assert {:error, :unauthorized} = Nexus.Auth.Cloud.authenticate(junk.("/api/platform/nexuses"))
    assert {:ok, %{tenant: "default"}} = Nexus.Auth.Cloud.authenticate(junk.("/"))
  end
end
