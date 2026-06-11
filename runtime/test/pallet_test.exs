defmodule Workbooks.PalletTest do
  use ExUnit.Case, async: false

  # Lane A — the prebuilt-WASI command pallet. The catalog-shape test runs always; the live
  # register-and-run test is @tag :pallet (it fetches the real artifacts over the network and runs
  # them under wasmtime) — run with `mix test test/pallet_test.exs --include pallet`.

  alias Workbooks.{Pallet, CommandRegistry}

  test "every catalog entry is well-formed + sha-pinned" do
    refute Pallet.catalog() == []

    for e <- Pallet.catalog() do
      assert is_binary(e.name) and e.name != ""
      assert String.starts_with?(e.url, "https://")
      assert Regex.match?(~r/^[0-9a-f]{64}$/, e.sha), "#{e.name} sha must be 64-hex pinned"
      assert is_binary(e.wasm_rel) and e.wasm_rel != ""
      assert e.mode in [:argv, :stdin1]
    end
  end

  @tag :pallet
  test "seed registers + RUNS coreutils and sqlite3 under wasmtime" do
    # coreutils — multicall: applet prepended to argv
    assert :ok = Pallet.seed_one("coreutils")
    assert {:ok, seq} = CommandRegistry.run("coreutils", "", ["seq", "5"])
    assert String.trim(seq) == "1\n2\n3\n4\n5"
    assert {:ok, wc} = CommandRegistry.run("coreutils", "a\nb\nc\n", ["wc", "-l"])
    assert String.trim(wc) == "3"

    # sqlite3 — SQL on stdin → result on stdout
    assert :ok = Pallet.seed_one("sqlite3")
    assert {:ok, out} =
             CommandRegistry.run(
               "sqlite3",
               "CREATE TABLE t(x);INSERT INTO t VALUES(42),(8);SELECT sum(x) FROM t;",
               []
             )

    assert out =~ "50"
  end
end
