defmodule Workbooks.ExpatLaneTest do
  @moduledoc """
  Proves the libexpat lane (streaming XML parsing, C→wasm32-wasip1): expat compiles via build_c_dir and parses
  an XML document with SAX handlers, counting elements + extracting text in-sandbox. Source provisioned by
  compilers/expat/build.sh (fetched, gitignored); skips if absent.
  """
  use ExUnit.Case, async: false
  alias Workbooks.PackageManager
  @src Path.expand(Path.join(__DIR__, "../compilers/expat/src"))
  @inc ["xmltok_impl.c", "xmltok_ns.c"]

  @tag :build
  @tag timeout: 300_000
  test "expat parses XML (SAX) — element count + text extraction in-sandbox" do
    if not File.regular?(Path.join(@src, "xmlparse.c")) do
      IO.puts("\n[skip] expat source not staged — run compilers/expat/build.sh")
    else
      assert {:ok, wasm, _} = PackageManager.build_c_dir(@src, ["-DHAVE_EXPAT_CONFIG_H"], @inc)
      on_exit(fn -> File.rm(wasm) end)
      out = PackageManager.run(wasm, "", [])
      out = if is_tuple(out), do: elem(out, 0), else: out
      assert out =~ "parse_ok=1"
      assert out =~ "items=2"
      assert out =~ "lasttext=world"
    end
  end
end
