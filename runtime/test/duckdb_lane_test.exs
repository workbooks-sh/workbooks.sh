defmodule Workbooks.DuckdbLaneTest do
  @moduledoc """
  Proves DuckDB (full SQL engine) LIVE in-sandbox: a duckdb.wasm built from C++ source (70 amalgamation TUs +
  shims, wasm32-wasip1) runs under our runtime and executes CREATE TABLE + INSERT + a GROUP-BY aggregate SELECT,
  returning correct rows. The 34MB artifact is provisioned by compilers/duckdb (heavy ~30min build; recipe in
  .campaign/forge-runs/duckdb-tolive2.md); the test skips if it isn't staged.
  """
  use ExUnit.Case, async: false
  alias Workbooks.PackageManager
  @duckdb Path.expand(Path.join(__DIR__, "../compilers/duckdb/duckdb.wasm"))

  @tag :build
  @tag timeout: 120_000
  test "DuckDB executes CREATE/INSERT/SELECT (GROUP BY aggregate) in-sandbox" do
    if not File.regular?(@duckdb) do
      IO.puts("\n[skip] duckdb.wasm not staged — see compilers/duckdb + forge-runs/duckdb-tolive2.md")
    else
      out = PackageManager.run(@duckdb, "", [])
      out = if is_tuple(out), do: elem(out, 0), else: out
      assert out =~ "SELECT-OK"
      assert out =~ ~r/x\s*\|\s*3\s*\|\s*18/   # COUNT=3, SUM=18 for group x
      assert out =~ ~r/y\s*\|\s*2\s*\|\s*19/
      assert out =~ "DUCKDB-LIVE-DONE"
    end
  end
end
