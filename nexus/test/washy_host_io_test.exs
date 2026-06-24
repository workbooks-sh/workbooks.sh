# a throwaway concern module at TOP LEVEL, exercising the `<concern>_<op>` → Nexus.Washy.Host<Concern>
# convention (must be a real top-level module name for Module.concat resolution to find it).
defmodule Nexus.Washy.HostFaketest do
  def handle("faketest_add", [a, b]), do: a + b
  def handle("faketest_echo", [x]), do: x
end

defmodule Nexus.WashyHostIOTest do
  @moduledoc "The host-import delegation seam: convention-based routing + graceful miss."
  use ExUnit.Case, async: true

  alias Nexus.Washy.HostIO

  test "dispatch routes <concern>_<op> to the convention module's handle/2" do
    assert HostIO.dispatch("faketest_add", [3, 4]) == 7
    assert HostIO.dispatch("faketest_echo", [42]) == 42
  end

  test "dispatch returns :no_host_module when no concern module exists" do
    assert HostIO.dispatch("nosuchconcern_op", []) == :no_host_module
    assert HostIO.dispatch("noseparator", []) == :no_host_module
  end
end
