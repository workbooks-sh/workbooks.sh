defmodule Nexus.CloudProviderTest do
  @moduledoc """
  wb-jr1py.1: the CloudProvider behaviour + registry — Fly conforms by construction, selection is
  config-driven, unknown providers fail closed everywhere (resolve, Nexus.Cloud, Nexus.Provisioner).
  """
  use ExUnit.Case, async: false

  alias Nexus.Config

  setup do
    prev = Config.cloud_provider()
    on_exit(fn ->
      Config.put(:cloud_provider, prev)
      Application.delete_env(:nexus, :cloud_providers)
    end)
    :ok
  end

  test "Nexus.Cloud.Fly exports every behaviour callback" do
    {:module, _} = Code.ensure_loaded(Nexus.Cloud.Fly)

    for {fun, arity} <- Nexus.CloudProvider.behaviour_info(:callbacks) do
      assert function_exported?(Nexus.Cloud.Fly, fun, arity),
             "Nexus.Cloud.Fly missing #{fun}/#{arity}"
    end
  end

  test "resolve: default (and explicit fly) → Nexus.Cloud.Fly" do
    Config.put(:cloud_provider, "fly")
    assert {:ok, Nexus.Cloud.Fly} = Nexus.CloudProvider.resolve()

    Config.put(:cloud_provider, nil)
    assert {:ok, Nexus.Cloud.Fly} = Nexus.CloudProvider.resolve()
  end

  test "resolve: unknown provider fails closed" do
    Config.put(:cloud_provider, "heroku")
    assert {:error, {:unknown_provider, "heroku"}} = Nexus.CloudProvider.resolve()
  end

  test "registry extends via app config (operator/test seam)" do
    defmodule FakeProvider do
      def configured?, do: false
    end

    Application.put_env(:nexus, :cloud_providers, %{"fake" => FakeProvider})
    Config.put(:cloud_provider, "fake")
    assert {:ok, FakeProvider} = Nexus.CloudProvider.resolve()
  end

  test "Nexus.Cloud verbs fail closed on an unknown provider — no broker call, no registry row" do
    Config.put(:cloud_provider, "heroku")
    tenant = "cp-test-#{System.unique_integer([:positive])}"

    assert {:error, {:unknown_provider, "heroku"}} = Nexus.Cloud.provision(tenant)
    assert {:error, :not_found} = Nexus.Cloud.get(tenant)
  end

  test "Nexus.Provisioner refuses a non-fly provider explicitly (fleet lane is fly-shaped)" do
    assert {:error, {:unsupported_provider, "cloudflare"}} =
             Nexus.Provisioner.provision("org1", provider: "cloudflare")
  end
end
