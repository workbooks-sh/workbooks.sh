defmodule Nexus.EnvRedactionTest do
  @moduledoc "Seam 0.2 / wb-cfk7: the env list view must not leak the exact plaintext length (an oracle)."
  use ExUnit.Case, async: false

  alias Nexus.ControlPlane.Env

  setup do
    prev = System.get_env("WB_ENV_MASTER_KEY")
    System.put_env("WB_ENV_MASTER_KEY", Base.encode64(:crypto.strong_rand_bytes(32)))
    on_exit(fn -> if prev, do: System.put_env("WB_ENV_MASTER_KEY", prev), else: System.delete_env("WB_ENV_MASTER_KEY") end)
    {:ok, org: "org_redaction_#{System.unique_integer([:positive])}"}
  end

  test "redacted env view exposes `present` (boolean) and NOT the exact `length`", %{org: org} do
    {:ok, _} = Env.create(org, %{name: "API_KEY", value: "a-secret-of-some-specific-length", scope: "nexus"})

    [view] = Env.list(org)

    refute Map.has_key?(view, :length), "exact length is a credential-fingerprinting oracle (wb-cfk7)"
    assert view.present == true
    assert view.masked == "••••••••"
    refute Map.has_key?(view, :value)
    refute Map.has_key?(view, :ciphertext)
  end
end
