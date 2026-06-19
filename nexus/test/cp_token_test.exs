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
    assert {:ok, @org} = Token.resolve(tok)

    listed = Token.list(@org)
    row = Enum.find(listed, &(&1.id == id))
    assert row.name == "my-laptop"
    refute Map.has_key?(row, :token)
    refute Map.has_key?(row, :org)
  end

  test "unknown / non-PAT tokens don't resolve" do
    assert :error = Token.resolve("wbk_nope")
    assert :error = Token.resolve("Bearer something")
    assert :error = Token.resolve("")
  end

  test "revoke kills the token" do
    %{token: tok, id: id} = Token.mint(@org, "ci")
    assert {:ok, @org} = Token.resolve(tok)
    Token.revoke(@org, id)
    assert :error = Token.resolve(tok)
  end

  test "Cloud adapter: a PAT authenticates to its org; junk falls through to JWT" do
    %{token: tok} = Token.mint(@org, "cli")

    pat_conn = Plug.Test.conn(:get, "/") |> Plug.Conn.put_req_header("authorization", "Bearer #{tok}")
    assert {:ok, %{tenant: @org, user: "cli"}} = Nexus.Auth.Cloud.authenticate(pat_conn)

    # A non-PAT bearer delegates to Nexus.Auth.Jwt, which (unconfigured here) rejects.
    junk_conn = Plug.Test.conn(:get, "/") |> Plug.Conn.put_req_header("authorization", "Bearer not-a-pat")
    assert {:error, _} = Nexus.Auth.Cloud.authenticate(junk_conn)
  end
end
