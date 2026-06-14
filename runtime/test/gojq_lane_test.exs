defmodule Workbooks.GojqLaneTest do
  @moduledoc """
  Proves the gojq lane (jq for JSON, Go→wasm32-wasip1): gojq.wasm runs in-sandbox and evaluates jq expressions
  over JSON from stdin (filters, arithmetic, raw output). Same Go→wasip1 provision path as esbuild/yq. Built by
  compilers/gojq/build.sh (gitignored); skips if not built.
  """
  use ExUnit.Case, async: false
  alias Workbooks.PackageManager
  @gojq Path.expand(Path.join(__DIR__, "../compilers/gojq/gojq.wasm"))

  @tag :build
  @tag timeout: 120_000
  test "gojq evaluates jq filters over JSON from stdin (field, arithmetic, raw)" do
    if not File.regular?(@gojq) do
      IO.puts("\n[skip] gojq.wasm not built — run compilers/gojq/build.sh")
    else
      json = ~s({"name":"workbooks","tags":["forge","wasm"],"n":21})
      assert run(json, [".name"]) =~ "workbooks"
      assert run(json, [".n * 2"]) =~ "42"
      assert run(json, ["-r", ".tags[0]"]) =~ "forge"
    end
  end

  defp run(stdin, args) do
    r = PackageManager.run(@gojq, stdin, args)
    if is_tuple(r), do: elem(r, 0), else: r
  end
end
