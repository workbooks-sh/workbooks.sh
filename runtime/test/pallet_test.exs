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

  test "csource catalog entries are well-formed + sha-pinned + carry build_opts" do
    refute Pallet.csource_catalog() == []

    for e <- Pallet.csource_catalog() do
      assert is_binary(e.name) and e.name != ""
      assert String.starts_with?(e.url, "https://")
      assert Regex.match?(~r/^[0-9a-f]{64}$/, e.sha), "#{e.name} sha must be 64-hex pinned"
      assert Keyword.keyword?(e.build_opts)
    end
  end

  @tag :pallet
  @tag timeout: 900_000
  test "every @csource tool builds in-sandbox + runs (full-catalog regression)" do
    # build + register each build-from-source tool — catches recipe rot (url/sha/source/lane changes)
    for e <- Pallet.csource_catalog() do
      assert :ok = Pallet.seed_csource_one(e.name), "#{e.name} should build + register from source"
      assert e.name in CommandRegistry.list()
    end

    # a representative smoke per category
    assert {:ok, lua} = CommandRegistry.run("lua", "", ["-e", "print(6*7)"])
    assert lua =~ "42"
    assert {:ok, qjs} = CommandRegistry.run("qjs", "", ["-e", "6*7"])
    assert qjs =~ "42"
    assert {:ok, wren} = CommandRegistry.run("wren", "", ["-e", "System.print(6*7)"])
    assert wren =~ "42"
    assert {:ok, md} = CommandRegistry.run("md", "# Hi", [])
    assert md =~ "<h1>"
    assert {:ok, b2} = CommandRegistry.run("b2", "abc", [])
    assert b2 =~ "ba80a53f"

    assert {:ok, gzc} = CommandRegistry.run("gz", "roundtrip-zlib", [])
    assert {:ok, gzb} = CommandRegistry.run("gz", gzc, ["-d"])
    assert gzb =~ "roundtrip-zlib"

    assert {:ok, l4c} = CommandRegistry.run("lz4", "roundtrip-lz4", [])
    assert {:ok, l4b} = CommandRegistry.run("lz4", l4c, ["-d"])
    assert l4b =~ "roundtrip-lz4"

    assert {:ok, zsc} = CommandRegistry.run("zstd", "roundtrip-zstd", [])
    assert {:ok, zsb} = CommandRegistry.run("zstd", zsc, ["-d"])
    assert zsb =~ "roundtrip-zstd"

    assert {:ok, qr} = CommandRegistry.run("qr", "test", [])
    assert qr =~ "##"

    assert {:ok, b3} = CommandRegistry.run("b3", "abc", [])
    assert b3 =~ "6437b3ac"

    assert {:ok, brc} = CommandRegistry.run("br", "roundtrip-brotli", [])
    assert {:ok, brb} = CommandRegistry.run("br", brc, ["-d"])
    assert brb =~ "roundtrip-brotli"

    assert {:ok, a2} = CommandRegistry.run("argon2", "password", [])
    assert String.length(String.trim(a2)) == 64
  end

  test "rust catalog entries are well-formed (Lane C)" do
    refute Pallet.rust_catalog() == []

    for r <- Pallet.rust_catalog() do
      assert is_binary(r.name) and r.name != ""
      assert is_binary(r.source) and r.source =~ "fn main"
      assert r.mode in [:argv, :stdin1]
    end
  end

  @tag :pallet
  @tag timeout: 300_000
  test "Lane C — a Rust tool builds in-sandbox (mrustc → clang) + runs" do
    # proves the Rust lane end-to-end as a registered command (std io + HashMap + sort, zero native exec)
    assert :ok = Pallet.seed_rust_one("wfreq")
    assert "wfreq" in CommandRegistry.list()
    assert {:ok, out} = CommandRegistry.run("wfreq", "the cat the dog the", [])
    assert out =~ "3\tthe"
  end
end
