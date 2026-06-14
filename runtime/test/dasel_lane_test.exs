defmodule Workbooks.DaselLaneTest do
  @moduledoc """
  Proves the dasel lane (multi-format data query, Go→wasm32-wasip1): one binary queries JSON/YAML/TOML (and
  XML/CSV) from stdin — covering config formats beyond yq/gojq. Same Go→wasip1 provision path. Built by
  compilers/dasel/build.sh (gitignored); skips if not built.
  """
  use ExUnit.Case, async: false
  alias Workbooks.PackageManager
  @dasel Path.expand(Path.join(__DIR__, "../compilers/dasel/dasel.wasm"))

  @tag :build
  @tag timeout: 120_000
  test "dasel queries JSON, YAML, and TOML from stdin through the runtime" do
    if not File.regular?(@dasel) do
      IO.puts("\n[skip] dasel.wasm not built — run compilers/dasel/build.sh")
    else
      assert run(~s({"name":"workbooks"}), ["-r", "json", ".name"]) =~ "workbooks"
      assert run("tags:\n  - forge\n  - wasm\n", ["-r", "yaml", ".tags.[1]"]) =~ "wasm"
      assert run("x = 42\n", ["-r", "toml", ".x"]) =~ "42"
    end
  end

  defp run(stdin, args) do
    r = PackageManager.run(@dasel, stdin, args)
    if is_tuple(r), do: elem(r, 0), else: r
  end
end
