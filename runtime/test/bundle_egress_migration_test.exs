defmodule Workbooks.BundleEgressMigrationTest do
  @moduledoc """
  Pins the egress migration (MAP.migrate + MAP.inferred): new artifacts are
  self-contained `.html` (the embedded form is the DEFAULT for `Bundle.ship`), while
  the legacy raw-zip `.wbundle` stays READABLE for back-compat. `read_any/1`
  dispatches both forms so restore/open/verify/unpack are transparent. Plus the
  inferred security adjacents that belong here: a zip-bomb size/ratio guard on
  unpack, and Manifest signing that is STABLE over the embedded form (signature
  binds the page, a `wb.bundle.sha256` assertion binds the swapped-payload case).

  Deterministic — no network/LLM. Signing uses a real ephemeral tenant did:key.
  """
  use ExUnit.Case, async: false
  alias Workbooks.Bundle

  # A throwaway tenant whose repo has an Ed25519 signing key (Workbooks.Git).
  setup do
    tenant = "egress-#{System.unique_integer([:positive])}"
    repo = Workbooks.Git.repo_path(tenant)
    File.mkdir_p!(repo)
    Workbooks.Git.did(tenant)
    on_exit(fn -> File.rm_rf!(repo) end)
    {:ok, tenant: tenant}
  end

  describe "default egress is the self-contained .html" do
    test "ship returns an .html carrying the embedded filesystem, not a raw zip" do
      out = Bundle.ship("wb-html-1", "<html><body>page</body></html>", "VFSBYTES")

      refute String.starts_with?(out, "PK"), "default egress must NOT be a raw zip"
      assert Bundle.embedded?(out)
      assert out =~ ">page<"

      # the embedded zip carries the filesystem (vfs + manifest), NOT a 2nd page copy
      parts = Bundle.unpack(Bundle.extract(out))
      assert parts["vfs.sqlite"] == "VFSBYTES"
      assert Map.has_key?(parts, "manifest.json")
      refute Map.has_key?(parts, "workbook.html")
    end

    test "explicit :wbundle egress still returns the legacy raw zip" do
      blob = Bundle.ship("wb-zip-1", "<html/>", "VFS", egress: :wbundle)
      assert String.starts_with?(blob, "PK")
      refute Bundle.embedded?(blob)
    end
  end

  describe "read_any/1 — both forms open transparently (no flag-day)" do
    test "restore handles the embedded .html (page is the carrier)" do
      html_egress = Bundle.ship("wb-r1", "<html><body>CARRIER</body></html>", "VFSX")
      {manifest, page, vfs} = Bundle.restore(html_egress)

      assert vfs == "VFSX"
      assert page =~ "CARRIER"
      assert manifest["format"] == "wbundle-html/1"
    end

    test "restore handles the legacy .wbundle (page packed inside)" do
      blob = Bundle.ship("wb-r2", "<html>LEGACY</html>", "VFSY", egress: :wbundle)
      {manifest, page, vfs} = Bundle.restore(blob)

      assert vfs == "VFSY"
      assert page == "<html>LEGACY</html>"
      assert manifest["format"] == "wbundle/1"
    end

    test "read_any passes a raw zip through and extracts from html" do
      blob = Bundle.pack(%{"a.txt" => "hi"})
      assert Bundle.read_any(blob) == blob

      html = Bundle.embed("<html><body></body></html>", blob)
      assert Bundle.read_any(html) == blob
    end

    test "read_any raises on neither-form input" do
      assert_raise ArgumentError, fn -> Bundle.read_any("just some text, not a bundle") end
    end
  end

  describe "Manifest signing over the embedded form (tamper-evident)" do
    test "a tenant-signed .html verifies; signature binds page+embedded zip", %{tenant: tenant} do
      signed = Bundle.ship("wb-sign-1", "<html><body>signed</body></html>", "VFSZ", tenant: tenant)

      assert Bundle.embedded?(signed)
      v = Bundle.verify(signed)
      assert v.valid, "freshly shipped + signed .html must verify: #{inspect(v)}"
      assert v.signature
      assert v.asset_integrity
    end

    test "swapping the embedded payload under the valid signature is caught", %{tenant: tenant} do
      signed = Bundle.ship("wb-sign-2", "<html><body>x</body></html>", "ORIGINAL-VFS", tenant: tenant)
      assert Bundle.verify(signed).valid

      # Swap ONLY the wb-bundle block's base64 in place — leaving every other byte
      # (so the page's asset hash still validates) and the signed manifest intact.
      # The signed wb.bundle.sha256 assertion must catch the substituted filesystem.
      evil_blob = Bundle.pack(%{"vfs.sqlite" => "TAMPERED", "manifest.json" => "{}"})
      evil_b64 = Base.encode64(evil_blob)

      tampered =
        Regex.replace(
          ~r/(<script[^>]*id="wb-bundle"[^>]*>).*?(<\/script>)/s,
          signed,
          "\\1#{evil_b64}\\2"
        )

      # the page bytes outside the bundle block are unchanged → asset hash still ok
      v = Bundle.verify(tampered)
      assert v.asset_integrity, "non-bundle page bytes were untouched"
      refute v.valid, "a swapped wb-bundle payload must fail the bundle_sha256 binding"
      assert v[:bundle_integrity] == false
    end

    test "embed/extract is signature-stable — re-extracting the page still verifies", %{tenant: tenant} do
      signed = Bundle.ship("wb-sign-3", "<html><body>stable</body></html>", "VFS", tenant: tenant)
      # restore returns the page itself; re-verifying that page must still pass.
      {_m, page, _vfs} = Bundle.restore(signed)
      assert Bundle.verify(page).valid
    end
  end

  describe "zip-bomb guard on unpack (the inferred security floor)" do
    test "an entry that inflates past the ACTUAL-output cap is rejected" do
      # The guard caps ACTUAL inflated output (not the attacker-declared size). Lower
      # the cap so a few-MB of zeros — which deflates to ~KB — is refused on output.
      Application.put_env(:workbooks, :bundle_max_entry_bytes, 1 * 1024 * 1024)
      on_exit(fn -> Application.delete_env(:workbooks, :bundle_max_entry_bytes) end)

      bomb = Bundle.pack(%{"bomb" => :binary.copy(<<0>>, 4 * 1024 * 1024)})
      assert_raise ArgumentError, ~r/zip-bomb guard/, fn -> Bundle.unpack(bomb) end
    end

    test "a normal bundle is unaffected by the guard" do
      parts = %{"a.txt" => "hello", "b.bin" => :crypto.strong_rand_bytes(2048)}
      assert Bundle.unpack(Bundle.pack(parts)) == parts
    end
  end

  describe "path-traversal (zip-slip) guard on write_tree" do
    setup do
      base = Path.join(System.tmp_dir!(), "egress_slip_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(base) end)
      {:ok, base: base}
    end

    test "a `..` or absolute entry name is refused, never written outside dir", %{base: base} do
      dst = Path.join(base, "dst")

      assert_raise ArgumentError, ~r/unsafe bundle path/, fn ->
        Bundle.write_tree(%{"../escape.txt" => "pwn"}, dst)
      end

      assert_raise ArgumentError, ~r/unsafe bundle path/, fn ->
        Bundle.write_tree(%{"/etc/escape.txt" => "pwn"}, dst)
      end

      refute File.exists?(Path.join(base, "escape.txt"))
    end
  end

  describe "read_tree applies the Private/session boundary (no secret leak)" do
    setup do
      base = Path.join(System.tmp_dir!(), "egress_priv_#{System.unique_integer([:positive])}")
      File.mkdir_p!(base)
      on_exit(fn -> File.rm_rf!(base) end)
      {:ok, base: base}
    end

    test "agent memory / session sidecars are stripped from a raw-tree bundle", %{base: base} do
      File.write!(Path.join(base, "index.html"), "<html><body>app</body></html>")
      File.write!(Path.join(base, "_steps.jsonl"), "secret session trace")
      File.mkdir_p!(Path.join(base, ".claude"))
      File.write!(Path.join(base, ".claude/memory.md"), "private agent memory")

      parts = Bundle.read_tree(base)

      assert Map.has_key?(parts, "index.html")
      refute Map.has_key?(parts, "_steps.jsonl"), "session sidecar must not ship"
      refute Enum.any?(Map.keys(parts), &String.contains?(&1, ".claude")), "agent memory must not ship"
    end
  end
end
