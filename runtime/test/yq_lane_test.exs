defmodule Workbooks.YqLaneTest do
  @moduledoc """
  Proves the yq lane (YAML processor, Go→wasm32-wasip1): yq.wasm runs in-sandbox under wasmtime and processes
  YAML from stdin. Same Go→wasip1 provision-time path as esbuild (native `go build`, sandboxed output). The
  artifact is built/staged by compilers/yq/build.sh (gitignored); the test skips if it isn't built yet.
  """
  use ExUnit.Case, async: false
  alias Workbooks.PackageManager

  @yq Path.expand(Path.join(__DIR__, "../compilers/yq/yq.wasm"))

  @tag :build
  @tag timeout: 120_000
  test "yq processes YAML from stdin through the runtime (scalar + nested array)" do
    if not File.regular?(@yq) do
      IO.puts("\n[skip] yq.wasm not built — run compilers/yq/build.sh")
    else
      yaml = "name: workbooks\nversion: 2\ntags: [forge, wasm]\n"

      name = PackageManager.run(@yq, yaml, [".name"])
      name = if is_tuple(name), do: elem(name, 0), else: name
      assert name =~ "workbooks"

      tag = PackageManager.run(@yq, yaml, [".tags[1]"])
      tag = if is_tuple(tag), do: elem(tag, 0), else: tag
      assert tag =~ "wasm"
    end
  end
end
