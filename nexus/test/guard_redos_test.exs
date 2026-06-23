defmodule Nexus.Auth.GuardRedosTest do
  @moduledoc "Seam 2.1 / wb-tcn9: a deep path can't amplify the ** glob recursion into a pre-auth CPU-DoS."
  use ExUnit.Case, async: false
  alias Nexus.Auth.Guard

  setup do
    Guard.reset()
    on_exit(&Guard.reset/0)
    :ok
  end

  test "a pathological deep path against a multi-** policy resolves fast (segment cap)" do
    Guard.protect("/**/a/**/b/**/c", role: "admin")
    deep = "/" <> Enum.map_join(1..5000, "/", fn _ -> "x" end)
    id = %{tenant: "t", roles: [], user: nil}

    {us, decision} = :timer.tc(fn -> Guard.decide("GET", deep, id) end)
    assert decision in [:unauthenticated, :forbidden, :allow]
    assert us < 200_000, "decide on a 5000-segment path took #{us}us — segment cap should bound it"
  end

  test "normal-depth routing still works" do
    Guard.public(["/health"])
    Guard.protect("/admin/**", role: "admin")
    anon = %{tenant: "t", roles: [], user: nil}
    admin = %{tenant: "t", roles: ["admin"], user: "u"}
    assert Guard.decide("GET", "/health", anon) == :allow
    assert Guard.decide("GET", "/admin/x", admin) == :allow
    assert Guard.decide("GET", "/admin/x", anon) in [:unauthenticated, :forbidden]
  end
end
