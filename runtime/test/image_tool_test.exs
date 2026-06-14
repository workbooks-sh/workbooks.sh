defmodule Workbooks.ImageToolTest do
  @moduledoc """
  Pins the agent's image tool GUARDS — every one short-circuits BEFORE
  ImageGen.generate, so this is deterministic (no image API call):
    • budget cap     — refuse once the per-run image budget is spent (cost guard)
    • empty prompt   — reject, don't burn a slot on an empty generation
    • empty path     — reject
    • path escape    — block writing outside the workdir (security), no file outside
    • no exec        — capability-gated off
  These protect cost + the host fs; they were untested.
  """
  use ExUnit.Case, async: true

  alias Workbooks.Agent

  defp img(args, st), do: Agent.__exec_one_for_test__(%{name: "image", args: args}, st)

  test "budget cap: an already-spent run refuses without generating" do
    {out, _st} = img(%{"prompt" => "a banner", "path" => "content/images/x.png"},
                     %{exec: true, images_used: 9_999, workdir: "/tmp"})
    assert out =~ "budget exhausted"
  end

  test "empty prompt is rejected (no wasted generation)" do
    {out, _st} = img(%{"prompt" => "", "path" => "content/images/x.png"},
                     %{exec: true, images_used: 0, workdir: "/tmp"})
    assert out =~ "prompt` is empty"
  end

  test "empty path is rejected" do
    {out, _st} = img(%{"prompt" => "a banner", "path" => ""},
                     %{exec: true, images_used: 0, workdir: "/tmp"})
    assert out =~ "path` is empty"
  end

  test "a path escaping the workdir is BLOCKED and nothing is written outside" do
    dir = Path.join(System.tmp_dir!(), "img-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    outside = Path.join(System.tmp_dir!(), "img-escape-#{System.unique_integer([:positive])}.png")
    on_exit(fn -> File.rm_rf(dir); File.rm_rf(outside) end)

    {out, _st} = img(%{"prompt" => "x", "path" => "../../../../../../#{Path.basename(outside)}"},
                     %{exec: true, images_used: 0, workdir: dir})
    assert out =~ "escapes your working dir"
    refute File.exists?(outside)
  end

  test "no exec capability → image not permitted" do
    {out, _st} = img(%{"prompt" => "x", "path" => "y.png"}, %{tenant: "t"})
    assert out =~ "not permitted"
  end
end
