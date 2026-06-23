defmodule Nexus.Auth.RoleCanonTest do
  @moduledoc "Seam 1.1 / wb-91gi: roles canonicalize so a mis-cased/garbage role can't bypass guards."
  use ExUnit.Case, async: true
  alias Nexus.Auth.Accounts

  test "known roles lowercase; mixed-case normalizes" do
    assert Accounts.canon_role("owner") == "owner"
    assert Accounts.canon_role("Owner") == "owner"
    assert Accounts.canon_role("ADMIN") == "admin"
  end

  test "unknown/garbage role drops to least privilege (viewer), never a higher tier" do
    assert Accounts.canon_role("superadmin") == "viewer"
    assert Accounts.canon_role("") == "viewer"
    assert Accounts.canon_role(nil) == "viewer"
    assert Accounts.canon_role("Owner ") == "viewer"
  end
end
