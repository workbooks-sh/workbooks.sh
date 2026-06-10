defmodule Workbooks.ImageGenTest do
  @moduledoc """
  HOST-BROKERED image generation (the `image` tool). Verifies the host-brokered
  contract end to end WITHOUT live HTTP, using the WB_IMAGE_FAKE=1 seam (the same
  env-flag style llm.ex uses to stay hermetic):

    1. data-URI decode — ImageGen.generate returns real decoded image bytes.
    2. happy path — the tool writes the bytes under the workdir + returns "ok ...".
    3. budget — the 3rd image call in a run is refused (2/run cap).
    4. path traversal — a `..` path escaping the workdir is rejected, nothing written.

  No System.cmd / native exec anywhere — the capability is pure brokered Elixir
  (asserted globally by no_native_exec_test).
  """
  use ExUnit.Case, async: false

  alias Workbooks.{Agent, ImageGen}

  setup do
    System.put_env("WB_IMAGE_FAKE", "1")
    on_exit(fn -> System.delete_env("WB_IMAGE_FAKE") end)

    wd = Path.join(System.tmp_dir!(), "imggen-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(wd)
    on_exit(fn -> File.rm_rf(wd) end)
    {:ok, wd: wd}
  end

  defp call(prompt, path, aspect \\ "16:9") do
    %{name: "image", id: "c", args: %{"prompt" => prompt, "path" => path, "aspect" => aspect}}
  end

  defp st(wd, opts \\ []) do
    %{
      exec: Keyword.get(opts, :exec, true),
      workdir: wd,
      images_used: Keyword.get(opts, :images_used, 0),
      last: %{}
    }
  end

  test "ImageGen.generate decodes a data URI to real image bytes (fake seam)" do
    assert {:ok, bin} = ImageGen.generate("a banner", "16:9")
    assert is_binary(bin) and byte_size(bin) > 0
    # The fake bytes are a real RIFF/WEBP container.
    assert <<"RIFF", _::binary-size(4), "WEBP", _::binary>> = bin
  end

  test "image tool writes bytes under the workdir and returns ok <path> (<bytes>)", %{wd: wd} do
    rel = "content/images/banner.webp"
    {out, s2} = Agent.__exec_one_for_test__(call("deep blue mesh", rel), st(wd))

    assert out =~ ~r/^ok content\/images\/banner\.webp \(\d+ bytes\)$/
    assert File.exists?(Path.join(wd, rel))
    assert byte_size(File.read!(Path.join(wd, rel))) > 0
    assert s2.images_used == 1
  end

  test "budget: the 3rd image call in a run is refused (2/run)", %{wd: wd} do
    {_o1, s1} = Agent.__exec_one_for_test__(call("a", "content/images/a.webp"), st(wd))
    assert s1.images_used == 1

    {_o2, s2} = Agent.__exec_one_for_test__(call("b", "content/images/b.webp"), s1)
    assert s2.images_used == 2

    {out3, s3} = Agent.__exec_one_for_test__(call("c", "content/images/c.webp"), s2)
    assert out3 =~ "image budget exhausted (2/run)"
    # Budget refusal does not write the file and does not advance the counter.
    assert s3.images_used == 2
    refute File.exists?(Path.join(wd, "content/images/c.webp"))
  end

  test "path traversal escaping the workdir is rejected, nothing written", %{wd: wd} do
    escape = "../../../../tmp/imggen-escape-#{:erlang.unique_integer([:positive])}.webp"
    {out, s2} = Agent.__exec_one_for_test__(call("x", escape), st(wd))

    assert out =~ "path escapes your working dir"
    refute File.exists?(Path.expand(Path.join(wd, escape)))
    # A rejected path is not a spent generation.
    assert s2.images_used == 0
  end

  test "image tool requires exec capability" do
    {out, _s} = Agent.__exec_one_for_test__(call("x", "content/images/x.webp"), st("/tmp", exec: false))
    assert out =~ "image not permitted (no exec capability)"
  end
end
