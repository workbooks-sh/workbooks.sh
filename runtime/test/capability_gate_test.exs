defmodule Workbooks.CapabilityGateTest do
  @moduledoc """
  The exec-capability boundary — the agent's core safety gate. `exec` permits the
  HOST-EFFECTING tools (git push, publish to the public site, image API + disk
  write); without it they must refuse, not run. (image's no-exec gate is pinned in
  image_tool_test.) shell is deliberately NOT gated — it's WASM-sandboxed +
  workdir-confined — so here we instead pin its malformed-arg resilience (a bad
  tool call bounces back as an error, never a crash). Deterministic.
  """
  use ExUnit.Case, async: true

  alias Workbooks.Agent

  defp exec(call, st), do: Agent.__exec_one_for_test__(call, st)

  test "git WITHOUT exec capability refuses (host push gated off)" do
    {out, _st} = exec(%{name: "git", args: %{"message" => "x"}}, %{tenant: "t"})
    assert out =~ "git not permitted"
  end

  test "publish WITHOUT exec capability refuses (public-site write gated off)" do
    {out, _st} = exec(%{name: "publish", args: %{}}, %{tenant: "t"})
    assert out =~ "publish not permitted"
  end

  test "shell with a missing/non-string pipeline bounces back as an error, never crashes" do
    {out, _st} = exec(%{name: "shell", args: %{}}, %{workdir: "/tmp", tenant: "t"})
    assert out =~ "required arg `pipeline`"

    {out2, _st} = exec(%{name: "shell", args: %{"pipeline" => 123}}, %{workdir: "/tmp", tenant: "t"})
    assert out2 =~ "required arg `pipeline`"
  end
end
