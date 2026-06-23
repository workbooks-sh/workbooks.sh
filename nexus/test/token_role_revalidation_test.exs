defmodule Nexus.ControlPlane.TokenRoleRevalidationTest do
  @moduledoc "Seam 1.1 / wb-mjsz: a PAT's effective role follows the LIVE account (minted role is a ceiling only)."
  use ExUnit.Case, async: false
  alias Nexus.ControlPlane.Token
  alias Nexus.Auth.Accounts

  test "live account role lower than the minted role wins (demotion semantics)" do
    Accounts.ensure()
    email = "reval_#{System.unique_integer([:positive])}@x.test"
    # the account is a MEMBER...
    {:ok, u} = Accounts.create(email, "pw-12345678", role: "member")
    # ...but a token is minted claiming admin (the frozen/minted role)
    %{token: tok} = Token.mint(u.org, "cli", role: "admin", user: u.id)
    # resolve must return the LIVE role (member), not the frozen admin
    assert {:ok, %{role: "member"}} = Token.resolve(tok)
  end

  test "minted role caps the live role (a token can't exceed what it was minted with)" do
    Accounts.ensure()
    email = "cap_#{System.unique_integer([:positive])}@x.test"
    {:ok, u} = Accounts.create(email, "pw-12345678", role: "admin")
    # token minted as member: even though the account is admin, the token stays member (ceiling)
    %{token: tok} = Token.mint(u.org, "cli", role: "member", user: u.id)
    assert {:ok, %{role: "member"}} = Token.resolve(tok)
  end

  test "a token with no backing account keeps its minted role (service/legacy)" do
    %{token: tok} = Token.mint("org_svc_#{System.unique_integer([:positive])}", "ci", role: "admin", user: "no_such_user")
    assert {:ok, %{role: "admin"}} = Token.resolve(tok)
  end
end
