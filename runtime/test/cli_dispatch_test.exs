defmodule Workbooks.CLIDispatchTest do
  @moduledoc """
  The `wb` CLI is the agent's primary tool surface (Agent.exec_one routes the
  'wb' tool → CLI.call/2). These pin the GRACEFUL-FALLBACK contract: an unknown
  or incomplete verb returns a usage string, never a crash — so a probing agent
  always gets actionable text back instead of an error.
  """
  use ExUnit.Case, async: true

  alias Workbooks.CLI

  test "no args → top-level usage" do
    out = CLI.call([], "dev")
    assert is_binary(out)
    assert out =~ "Workbook CLI"
  end

  test "an unknown verb degrades to usage, never raises" do
    out = CLI.call(["totally-bogus-verb-zzz"], "dev")
    assert is_binary(out)
    assert out =~ "Workbook CLI"
  end

  test "incomplete subcommands return their own usage line" do
    assert CLI.call(["app"], "dev") =~ "usage: wb app"
    assert CLI.call(["env"], "dev") =~ "usage: wb env request"
    assert CLI.call(["models"], "dev") =~ "usage: wb models list"
    assert CLI.call(["model"], "dev") =~ "usage: wb model"
    assert CLI.call(["workgate"], "dev") =~ "usage: wb workgate request"
  end

  test "model get returns a concrete id (regression: not the opaque '(default)')" do
    out = CLI.call(["model", "get"], "dev")
    refute out == "(default)"
    assert out =~ "/"
  end
end
