defmodule Workbooks.Deploy.ConfigTest do
  @moduledoc """
  Pins Workbooks.Deploy.Config.validate/1 — the secure-by-default gate `work deploy
  validate`/`apply` runs before standing up a runtime. The headline invariant
  (wb-oom): a CLOUD deploy must never be left OPEN. `cloud` + `trusted` auth +
  no WB_PUBLIC_BEARER is an unauthenticated control plane (anyone can drive
  /api/run, /rcp/* via a spoofable x-tenant header) and must be REFUSED, not
  shipped. Deterministic (pure config + env checks, no network).
  """
  use ExUnit.Case, async: false
  alias Workbooks.Deploy.Config

  setup do
    on_exit(fn -> System.delete_env("WB_PUBLIC_BEARER") end)
    :ok
  end

  # Minimal single-tenant cloud config; merge overrides per test.
  defp cfg(extra \\ %{}) do
    Map.merge(
      %{"ENGINE_PLACE" => "cloud", "TENANCY_MODE" => "single", "STORAGE" => "local-fs",
        "DATABASE" => "sqlite", "AUTH" => "trusted"},
      extra
    )
  end

  defp issues(p) do
    case Config.validate(p) do
      :ok -> []
      {:error, list} -> list
    end
  end

  test "cloud + trusted + NO WB_PUBLIC_BEARER → refused (open control plane)" do
    System.delete_env("WB_PUBLIC_BEARER")
    msgs = issues(cfg())
    assert Enum.any?(msgs, &(&1 =~ "OPEN control plane")), "expected an open-control-plane error, got: #{inspect(msgs)}"
  end

  test "cloud + trusted + WB_PUBLIC_BEARER set → locked, validates clean" do
    System.put_env("WB_PUBLIC_BEARER", "a-shared-secret")
    assert Config.validate(cfg()) == :ok
  end

  test "LOCAL + trusted + no bearer → fine (a local daemon is not a public surface)" do
    System.delete_env("WB_PUBLIC_BEARER")
    refute Enum.any?(issues(cfg(%{"ENGINE_PLACE" => "local"})), &(&1 =~ "OPEN control plane"))
  end

  test "cloud + real AUTH (multi-tenant, postgres) → not flagged as open even without a bearer" do
    System.delete_env("WB_PUBLIC_BEARER")
    System.put_env("WB_DATABASE_URL", "postgres://u:p@h/db")
    on_exit(fn -> System.delete_env("WB_DATABASE_URL") end)

    p = cfg(%{"TENANCY_MODE" => "multi", "AUTH" => "betterauth", "ISSUER" => "https://id.example.com", "DATABASE" => "postgres"})
    refute Enum.any?(issues(p), &(&1 =~ "OPEN control plane"))
  end

  # Regression guards for the sibling tenancy invariants the gate sits beside.
  test "multi-tenant on sqlite is refused (single-writer serialization)" do
    System.put_env("WB_PUBLIC_BEARER", "x")
    assert Enum.any?(issues(cfg(%{"TENANCY_MODE" => "multi", "AUTH" => "betterauth", "ISSUER" => "https://i", "DATABASE" => "sqlite"})),
                     &(&1 =~ "serializes every tenant"))
  end

  test "multi-tenant with trusted auth is refused (no identity to isolate by)" do
    System.put_env("WB_PUBLIC_BEARER", "x")
    assert Enum.any?(issues(cfg(%{"TENANCY_MODE" => "multi", "AUTH" => "trusted", "DATABASE" => "postgres"})),
                     &(&1 =~ "needs real AUTH"))
  end
end
