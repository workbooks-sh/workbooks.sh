defmodule Nexus.ResourcesAccountTest do
  @moduledoc """
  Tests for wb-90sp: the generic data explorer must NOT surface per-user `account` resources
  (profiles, device keys) — they hold one person's private rows and have their own gated UIs.
  """
  use ExUnit.Case, async: true
  alias Nexus.Resources

  test "account?/1 is true only for resources tagged \"account\"" do
    assert Resources.account?(%{tags: ["system", "account"]})
    refute Resources.account?(%{tags: ["system", "agents"]})
    refute Resources.account?(%{tags: []})
    refute Resources.account?(%{})
  end

  test "explorable/1 drops account resources, keeps the rest" do
    entries = [
      %{name: "DeviceKey", tags: ["system", "account"]},
      %{name: "Profile", tags: ["system", "account"]},
      %{name: "Run", tags: ["system", "agents"]},
      %{name: "Todo", tags: ["system", "orchestration"]}
    ]

    names = Resources.explorable(entries) |> Enum.map(& &1.name)
    assert names == ["Run", "Todo"]
    refute "DeviceKey" in names
    refute "Profile" in names
  end
end
