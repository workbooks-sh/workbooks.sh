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
      assert e.kind in [:wasm, :archive, :archive_many, :zip]
      assert String.starts_with?(e.url, "https://")
      assert Regex.match?(~r/^[0-9a-f]{64}$/, e.sha), "#{e.name} sha must be 64-hex pinned"
      assert e.mode in [:argv, :stdin1]
      # archives/zips carry the inner wasm path; multi-archives carry {name, rel} entries
      case e.kind do
        k when k in [:archive, :zip] -> assert is_binary(e.wasm_rel) and e.wasm_rel != ""
        :archive_many -> assert is_list(e.entries) and e.entries != []
        :wasm -> :ok
      end
    end
  end

  @tag :pallet
  test "seed registers + RUNS every pallet tool under wasmtime" do
    # Language runtimes (single .wasm)
    assert :ok = Pallet.seed_one("python")
    assert {:ok, py} = CommandRegistry.run("python", "", ["-c", "print(2**10)"])
    assert py =~ "1024"

    assert :ok = Pallet.seed_one("ruby")
    assert {:ok, rb} = CommandRegistry.run("ruby", "", ["-e", "puts 2**10"])
    assert rb =~ "1024"

    assert :ok = Pallet.seed_one("wasm3")
    assert {:ok, w3} = CommandRegistry.run("wasm3", "", ["--version"])
    assert w3 =~ "Wasm3"

    # WABT — one tarball → 12 commands (register-many)
    assert :ok = Pallet.seed_one("wabt")
    assert {:ok, w2w} = CommandRegistry.run("wat2wasm", "", ["--version"])
    assert w2w =~ "1.0.41"
    assert {:ok, w2t} = CommandRegistry.run("wasm2wat", "", ["--version"])
    assert w2t =~ "1.0.41"

    for t <-
          ~w(wat2wasm wasm2wat wasm-validate wasm-decompile wasm-interp wasm-objdump
             wasm-stats wasm-strip wasm2c wast2json wat-desugar spectest-interp) do
      assert t in CommandRegistry.list(), "#{t} should be registered"
    end

    # prolog (trealla) — .zip unpacked via Erlang :zip; -g one-shot goal
    assert :ok = Pallet.seed_one("prolog")
    assert {:ok, p} = CommandRegistry.run("prolog", "", ["-g", "X is 6*7, write(X), nl, halt"])
    assert p =~ "42"

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
