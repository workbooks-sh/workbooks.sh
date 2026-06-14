defmodule Workbooks.JsonnetLaneTest do
  @moduledoc """
  Proves the jsonnet lane (google/go-jsonnet config templating language, Go→wasm32-wasip1): evaluates a jsonnet
  program (arithmetic, list comprehensions, stdlib) to JSON in-sandbox. Config-generation language, beyond the
  format-query tools. Built by compilers/jsonnet/build.sh (gitignored); skips if not built.
  """
  use ExUnit.Case, async: false
  alias Workbooks.PackageManager
  @jsonnet Path.expand(Path.join(__DIR__, "../compilers/jsonnet/jsonnet.wasm"))

  @tag :build
  @tag timeout: 120_000
  test "jsonnet evaluates a program to JSON in-sandbox (arithmetic + comprehension + stdlib)" do
    if not File.regular?(@jsonnet) do
      IO.puts("\n[skip] jsonnet.wasm not built — run compilers/jsonnet/build.sh")
    else
      r = PackageManager.run(@jsonnet, "", ["-e", "{a: 1, sum: 2+3, sq: [x*x for x in std.range(1,3)]}"])
      out = if is_tuple(r), do: elem(r, 0), else: r
      flat = String.replace(to_string(out), ~r/\s+/, "")
      assert flat =~ ~s("a":1)
      assert flat =~ ~s("sum":5)            # arithmetic
      assert flat =~ ~s("sq":[1,4,9])       # list comprehension + stdlib std.range
    end
  end
end
