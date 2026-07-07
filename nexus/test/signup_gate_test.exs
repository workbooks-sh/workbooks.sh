defmodule Nexus.SignupGateTest do
  @moduledoc """
  The signup gate (wb-review-p0.1). A broker-token-holding control plane must FAIL CLOSED: with no
  WB_LOGIN_ALLOWLIST it refuses new-account creation (native /auth/signup AND GitHub-OAuth first login)
  unless the operator explicitly opens it — so the lock is a property of the code, not an invisible
  runtime secret. A self-host / dev nexus (no control-plane role) keeps the neutral open default.
  """
  use ExUnit.Case, async: false

  setup do
    on_exit(fn ->
      Enum.each(~w(WB_CONTROL_PLANE WB_LOGIN_ALLOWLIST WB_LOGIN_OPEN), &System.delete_env/1)
    end)
  end

  describe "signups_open?/0" do
    test "self-host / dev (no control plane, no allowlist) → open (neutral default)" do
      System.delete_env("WB_CONTROL_PLANE")
      System.delete_env("WB_LOGIN_ALLOWLIST")
      assert Nexus.Config.signups_open?() == true
    end

    test "control plane + no allowlist + not opened → FAIL CLOSED" do
      System.put_env("WB_CONTROL_PLANE", "1")
      System.delete_env("WB_LOGIN_ALLOWLIST")
      System.delete_env("WB_LOGIN_OPEN")
      refute Nexus.Config.signups_open?(), "control plane with no allowlist must refuse public signup"
    end

    test "control plane + explicit WB_LOGIN_OPEN=1 → open (operator opt-in)" do
      System.put_env("WB_CONTROL_PLANE", "1")
      System.delete_env("WB_LOGIN_ALLOWLIST")
      System.put_env("WB_LOGIN_OPEN", "1")
      assert Nexus.Config.signups_open?() == true
    end

    test "control plane + allowlist set → open (membership then enforced by login_permitted?/1)" do
      System.put_env("WB_CONTROL_PLANE", "1")
      System.put_env("WB_LOGIN_ALLOWLIST", "owner@example.com")
      assert Nexus.Config.signups_open?() == true
    end
  end

  describe "login_permitted?/1" do
    test "empty allowlist ⇒ everyone" do
      System.delete_env("WB_LOGIN_ALLOWLIST")
      assert Nexus.Config.login_permitted?("anyone@example.com")
    end

    test "set allowlist ⇒ only members (case-insensitive), everyone else refused" do
      System.put_env("WB_LOGIN_ALLOWLIST", "Owner@Example.com, second@example.com")
      assert Nexus.Config.login_permitted?("owner@example.com")
      assert Nexus.Config.login_permitted?("SECOND@EXAMPLE.COM")
      refute Nexus.Config.login_permitted?("stranger@example.com")
    end
  end
end
