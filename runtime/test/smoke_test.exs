defmodule Workbooks.SmokeTest do
  use ExUnit.Case, async: true

  test "CommandRegistry.list/0 returns a list" do
    cmds = Workbooks.CommandRegistry.list()
    assert is_list(cmds)
  end
end
