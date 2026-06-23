defmodule Nexus.TokenRevokeToctouTest do
  @moduledoc "Seam 0.2 / wb-m6oz: a revoked token's last_used_at write-back must not resurrect the row."
  use ExUnit.Case, async: false

  alias Nexus.Auth.TokenStore

  setup do
    TokenStore.ensure(:auth_tokens)
    :ok
  end

  test "touch on a deleted row is a no-op — revocation is not undone" do
    hash = "h_#{System.unique_integer([:positive])}"
    TokenStore.put(:auth_tokens, hash, "tenant_x", "tok_1", %{tenant: "tenant_x", id: "tok_1", last_used_at: nil})
    assert {:ok, _} = TokenStore.get(:auth_tokens, hash)

    # simulate the TOCTOU: revoke lands, THEN the in-flight resolve's write-back fires
    TokenStore.revoke(:auth_tokens, "tenant_x", "tok_1")
    TokenStore.touch(:auth_tokens, hash, %{tenant: "tenant_x", id: "tok_1", last_used_at: 123})

    # the deleted row stays deleted — with the old INSERT-OR-REPLACE write-back it would be back
    assert :error = TokenStore.get(:auth_tokens, hash)
  end

  test "touch on an existing row updates it" do
    hash = "h_#{System.unique_integer([:positive])}"
    TokenStore.put(:auth_tokens, hash, "tenant_y", "tok_2", %{tenant: "tenant_y", id: "tok_2", last_used_at: nil})
    TokenStore.touch(:auth_tokens, hash, %{tenant: "tenant_y", id: "tok_2", last_used_at: 999})
    assert {:ok, %{last_used_at: 999}} = TokenStore.get(:auth_tokens, hash)
  end
end
