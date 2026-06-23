defmodule Nexus.Auth.InviteRankCapTest do
  @moduledoc "Seam 1.2 / wb-wbm6: an inviter can't grant a role above their own rank."
  use ExUnit.Case, async: true
  alias Nexus.Auth.Accounts

  test "rank ordering" do
    assert Accounts.rank("owner") > Accounts.rank("admin")
    assert Accounts.rank("admin") > Accounts.rank("member")
    assert Accounts.rank("member") > Accounts.rank("viewer")
    assert Accounts.rank("superadmin") == 0
  end

  test "an admin cannot out-rank themselves (owner > admin)" do
    # the platform handler compares rank(invited) > rank(caller); prove the comparison an admin would hit
    assert Accounts.rank("owner") > Accounts.rank("admin")
    refute Accounts.rank("member") > Accounts.rank("admin")
    refute Accounts.rank("admin") > Accounts.rank("admin")
  end
end
