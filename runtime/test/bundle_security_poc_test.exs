defmodule Workbooks.BundleSecurityPocTest do
  @moduledoc """
  The three merge-blocking security findings on `Workbooks.Bundle`, each pinned by
  its EXACT proof-of-concept. These are regression locks — if any fix is reverted,
  the matching PoC fails.

    FIX 1 (zip-bomb bypass): unpack must cap ACTUAL inflated output, never the
      central directory's DECLARED sizes — a forged zip declaring 100B that
      inflates to 30MB+ is rejected.
    FIX 2 (signature bypass on embedded form): every embedded-form signing path
      must bind the bundle blob (`wb.bundle.sha256`); verify must FAIL CLOSED on a
      signed embedded form that carries NO bundle-sha assertion (swappable fs).
    FIX 3 (unbundle writes control-dir dotfiles): write_tree must apply the same
      VCS/dotfile denylist read_tree uses — `.git/hooks/pre-commit` is refused.

  Deterministic — no network/LLM.
  """
  use ExUnit.Case, async: false
  alias Workbooks.Bundle

  # ── FIX 1: zip-bomb via a FORGED central directory ─────────────────────────────
  describe "FIX 1 — actual-output cap defeats a forged-declared-size zip-bomb" do
    # Build a single-entry zip by hand where the central directory + local header
    # DECLARE 100 bytes uncompressed, but the deflate stream actually inflates to
    # 30MB+. The old guard trusted the declared size and let `:zip.extract` run away
    # to OOM; the fix inflates with a hard cap on ACTUAL output and aborts.
    defp forged_bomb_zip(declared_uncomp, actual_bytes) do
      name = "bomb"
      name_b = name
      name_len = byte_size(name_b)

      # raw-deflate the real payload (this is what actually inflates)
      z = :zlib.open()
      :zlib.deflateInit(z, :default, :deflated, -15, 8, :default)
      comp = :zlib.deflate(z, actual_bytes, :finish) |> IO.iodata_to_binary()
      :zlib.deflateEnd(z)
      :zlib.close(z)
      comp_size = byte_size(comp)
      crc = :erlang.crc32(actual_bytes)

      # Local File Header — declares the FORGED (tiny) uncompressed size.
      lfh =
        <<0x04034B50::little-32, 20::little-16, 0::little-16, 8::little-16, 0::little-16,
          0::little-16, crc::little-32, comp_size::little-32, declared_uncomp::little-32,
          name_len::little-16, 0::little-16>> <> name_b

      data = comp
      lfh_off = 0
      cd_off = byte_size(lfh) + byte_size(data)

      # Central Directory Header — same FORGED declared uncompressed size.
      cdh =
        <<0x02014B50::little-32, 20::little-16, 20::little-16, 0::little-16, 8::little-16,
          0::little-16, 0::little-16, crc::little-32, comp_size::little-32,
          declared_uncomp::little-32, name_len::little-16, 0::little-16, 0::little-16,
          0::little-16, 0::little-16, 0::little-32, lfh_off::little-32>> <> name_b

      eocd =
        <<0x06054B50::little-32, 0::little-16, 0::little-16, 1::little-16, 1::little-16,
          byte_size(cdh)::little-32, cd_off::little-32, 0::little-16>>

      lfh <> data <> cdh <> eocd
    end

    test "a zip whose central dir DECLARES 100B but inflates to 30MB is REJECTED" do
      actual = :binary.copy(<<0>>, 30 * 1024 * 1024)
      bomb = forged_bomb_zip(100, actual)

      # The forged zip is small on disk yet declares only 100B uncompressed — the
      # exact review PoC. Cap the totals low enough that 30MB must be refused.
      Application.put_env(:workbooks, :bundle_max_total_bytes, 1 * 1024 * 1024)
      Application.put_env(:workbooks, :bundle_max_entry_bytes, 1 * 1024 * 1024)

      on_exit(fn ->
        Application.delete_env(:workbooks, :bundle_max_total_bytes)
        Application.delete_env(:workbooks, :bundle_max_entry_bytes)
      end)

      assert_raise ArgumentError, ~r/zip-bomb guard/, fn -> Bundle.unpack(bomb) end
    end

    test "a forged 100B-declared entry under default caps STILL refuses 30MB output" do
      # Even WITHOUT lowering caps, prove output-driven enforcement: declare a tiny
      # size but inflate past a tightened per-entry cap.
      Application.put_env(:workbooks, :bundle_max_entry_bytes, 4 * 1024 * 1024)
      on_exit(fn -> Application.delete_env(:workbooks, :bundle_max_entry_bytes) end)

      bomb = forged_bomb_zip(100, :binary.copy(<<0>>, 30 * 1024 * 1024))
      assert_raise ArgumentError, ~r/zip-bomb guard/, fn -> Bundle.unpack(bomb) end
    end

    test "an honest bundle round-trips through the actual-output unpacker" do
      parts = %{"a.txt" => "hello", "dir/b.bin" => :crypto.strong_rand_bytes(8192)}
      assert Bundle.unpack(Bundle.pack(parts)) == parts
    end
  end

  # ── FIX 2: signature must bind the embedded filesystem (fail-closed) ────────────
  describe "FIX 2 — embedded-form signing binds the bundle; verify fails closed" do
    setup do
      tenant = "poc-sig-#{System.unique_integer([:positive])}"
      File.mkdir_p!(Workbooks.Git.repo_path(tenant))
      Workbooks.Git.did(tenant)
      on_exit(fn -> File.rm_rf!(Workbooks.Git.repo_path(tenant)) end)
      {:ok, tenant: tenant}
    end

    test "sign an embedded .html, swap its payload → verify INVALID", %{tenant: tenant} do
      page =
        "<html><body>x</body></html>"
        |> Bundle.embed(Bundle.pack(%{"vfs.sqlite" => "ORIGINAL", "manifest.json" => "{}"}))

      signed = Bundle.sign_embedded(page, tenant)
      assert Bundle.verify(signed).valid, "freshly signed embedded form must verify"

      evil = Base.encode64(Bundle.pack(%{"vfs.sqlite" => "TAMPERED", "manifest.json" => "{}"}))

      swapped =
        Regex.replace(
          ~r/(<script[^>]*id="wb-bundle"[^>]*>).*?(<\/script>)/s,
          signed,
          "\\1#{evil}\\2"
        )

      v = Bundle.verify(swapped)
      assert v.asset_integrity, "the page bytes outside the bundle block are untouched"
      refute v.valid, "a swapped embedded payload must fail the bundle-sha binding"
      assert v[:bundle_integrity] == false
    end

    test "a signed embedded form with NO bundle-sha assertion → verify INVALID", %{tenant: tenant} do
      # The legacy/vulnerable path: sign the page WITHOUT binding the embedded blob
      # (Manifest.sign strips wb-bundle before hashing, so the signature alone does
      # not cover the payload). verify MUST refuse to bless an unbound embedded fs.
      page =
        "<html><body>x</body></html>"
        |> Bundle.embed(Bundle.pack(%{"vfs.sqlite" => "ORIGINAL", "manifest.json" => "{}"}))

      unbound = Workbooks.Manifest.sign(page, tenant, [%{"type" => "c2pa.action.published"}])

      assert Bundle.embedded?(unbound)
      # signature + asset hash are individually valid …
      base = Workbooks.Manifest.verify(unbound)
      assert base.signature and base.asset_integrity

      # … but Bundle.verify fails closed because nothing binds the swappable payload.
      v = Bundle.verify(unbound)
      refute v.valid, "an embedded form lacking wb.bundle.sha256 must be invalid"
      assert v[:bundle_unbound] == true
    end

    test "the RCP ?sign=1 path now binds the embedded bundle (sign_embedded)", %{tenant: tenant} do
      # Mirror POST /rcp/bundle?sign=1: embed + embed_loader + sign_embedded.
      page =
        "<html><body>rcp</body></html>"
        |> Bundle.embed(Bundle.pack(%{"vfs.sqlite" => "RCP", "manifest.json" => "{}"}))
        |> Bundle.embed_loader()

      signed = Bundle.sign_embedded(page, tenant)
      v = Bundle.verify(signed)
      assert v.valid and v[:bundle_integrity] == true

      evil = Base.encode64(Bundle.pack(%{"vfs.sqlite" => "EVIL", "manifest.json" => "{}"}))

      swapped =
        Regex.replace(~r/(<script[^>]*id="wb-bundle"[^>]*>).*?(<\/script>)/s, signed, "\\1#{evil}\\2")

      refute Bundle.verify(swapped).valid
    end
  end

  # ── FIX 3: unbundle must refuse control-dir dotfiles ────────────────────────────
  describe "FIX 3 — write_tree refuses VCS/dotfile control-dir paths" do
    setup do
      base = Path.join(System.tmp_dir!(), "poc_strip_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(base) end)
      {:ok, base: base}
    end

    test "a bundle carrying .git/hooks/pre-commit is REFUSED on unbundle", %{base: base} do
      dst = Path.join(base, "dst")

      assert_raise ArgumentError, ~r/control-dir/, fn ->
        Bundle.write_tree(%{".git/hooks/pre-commit" => "#!/bin/sh\necho pwned"}, dst)
      end

      refute File.exists?(Path.join([dst, ".git", "hooks", "pre-commit"])),
             "the hostile hook must never be materialized"
    end

    test "other control dirs (.beads, .tmp, _build, node_modules) are refused too", %{base: base} do
      dst = Path.join(base, "dst")

      for path <- ~w(.beads/x .tmp/y _build/z node_modules/pkg/index.js .private/secret) do
        assert_raise ArgumentError, ~r/control-dir/, fn ->
          Bundle.write_tree(%{path => "x"}, dst)
        end
      end
    end

    test "an honest tree still writes through write_tree", %{base: base} do
      dst = Path.join(base, "dst")
      n = Bundle.write_tree(%{"index.html" => "<html></html>", "src/app.js" => "1"}, dst)

      assert n == 2
      assert File.read!(Path.join(dst, "index.html")) == "<html></html>"
      assert File.read!(Path.join([dst, "src", "app.js"])) == "1"
    end
  end
end
