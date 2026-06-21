defmodule Nexus.ConfigModeTest do
  @moduledoc "The deploy-block MODE knobs → runtime adapter selection (the local↔cloud parity keystone)."
  use ExUnit.Case, async: false
  alias Nexus.Config

  # Config is a global :persistent_term; restore the empty default after each test.
  setup do
    on_exit(fn -> Config.load("") end)
    :ok
  end

  defp block(body), do: "deploy do\n#{body}\nend\n"

  test "defaults (no deploy block) match today's behavior — trusted/single/sqlite" do
    Config.load("")
    assert Config.auth() == "trusted"
    assert Config.auth_adapter() == Nexus.Auth.None
    assert Config.database() == "sqlite"
    assert Config.store_adapter() == Nexus.Store.Sqlite
    assert Config.tenancy_mode() == "single"
    # cloud-tier machine shape by default (so local doesn't mask OOM/concurrency)
    assert Config.cpus() == 1
    assert Config.memory() == 1024
  end

  test "auth mode selects the request-auth adapter (same on every target)" do
    Config.load(block(~s(  auth="trusted")))
    assert Config.auth_adapter() == Nexus.Auth.None

    Config.load(block(~s(  auth="bearer")))
    assert Config.auth_adapter() == Nexus.Auth.Bearer

    for m <- ~w(oidc betterauth clerk auth0) do
      Config.load(block(~s(  auth="#{m}")))
      assert Config.auth_adapter() == Nexus.Auth.Jwt, "#{m} should select Jwt"
    end
  end

  test "database=postgres surfaces a loud :postgres_unimplemented (no silent SQLite fallback)" do
    Config.load(block(~s(  database="postgres")))
    assert Config.store_adapter() == :postgres_unimplemented
  end

  test "machine shape is overridable from the block for tier-faithful local testing" do
    Config.load(block(~s(  cpus="2"\n  memory="2048")))
    assert Config.cpus() == 2
    assert Config.memory() == 2048
  end
end
