defmodule Nexus.WaitlistTest do
  use ExUnit.Case, async: false

  # Nexus.Waitlist is started by the application's supervision tree, so use the
  # running instance. Tests use a unique email + clean it up.
  @email "wl-test-#{System.unique_integer([:positive])}@example.com"

  setup do
    on_exit(fn -> Nexus.Waitlist.delete(@email) end)
    :ok
  end

  test "stores a valid email + interest, dedups + normalizes by email" do
    assert :ok = Nexus.Waitlist.add(String.upcase(@email) <> " ", "building-with-agents")
    assert :ok = Nexus.Waitlist.add(@email, "team-collaboration")
    rows = Enum.filter(Nexus.Waitlist.list(), &(&1.email == @email))
    assert length(rows) == 1
    assert hd(rows).interest == "team-collaboration"
  end

  test "rejects a bad email" do
    assert {:error, :invalid_email} = Nexus.Waitlist.add("not-an-email", "x")
    assert {:error, :invalid_email} = Nexus.Waitlist.add("", "x")
  end
end
