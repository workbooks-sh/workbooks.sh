defmodule Workbooks.WbToolTest do
  @moduledoc """
  Pins the `wb` agent tool — the toolkit's core execution path, LIVE-PROVED this
  session (Waldo ran `wb model get` and reported the model). The tool does
  OptionParser.split(args) → Workbooks.CLI.call(argv, tenant), so this pins the
  arg parse, the tenant threading, and the model get/set round-trip — all
  deterministic (Vars lookup, no LLM / network). Mirrors the live proof.
  """
  use ExUnit.Case, async: false

  alias Workbooks.Agent

  setup do
    dir = Path.join(System.tmp_dir!(), "wbtool-#{System.unique_integer([:positive])}")
    prev = System.get_env("WB_DATA")
    System.put_env("WB_DATA", dir)
    on_exit(fn ->
      File.rm_rf(dir)
      if prev, do: System.put_env("WB_DATA", prev), else: System.delete_env("WB_DATA")
    end)
    :ok
  end

  defp wb(args, tenant), do: Agent.__exec_one_for_test__(%{name: "wb", args: %{"args" => args}}, %{tenant: tenant})

  test "`wb model get` for a fresh tenant returns the default model (matches the live proof)" do
    {out, _st} = wb("model get", "wbtool-fresh-#{System.unique_integer([:positive])}")
    assert out =~ "mimo"
    assert out =~ "default"
  end

  test "`wb model set` then `wb model get` round-trips per-tenant through the tool" do
    tenant = "wbtool-rt-#{System.unique_integer([:positive])}"
    {_set, _} = wb("model set anthropic/claude-haiku-4-5", tenant)
    {out, _} = wb("model get", tenant)
    assert out =~ "anthropic/claude-haiku-4-5"

    # another tenant is unaffected (per-tenant isolation through the tool)
    {other, _} = wb("model get", "wbtool-other-#{System.unique_integer([:positive])}")
    refute other =~ "claude-haiku-4-5"
  end
end
