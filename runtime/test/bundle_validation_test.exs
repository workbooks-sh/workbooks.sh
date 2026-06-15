defmodule Workbooks.BundleValidationTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Deep-validation of the Workbook bundle at 120% — empirical robustness proof
  (wb-mv3d). Hermetic: pure zip/sign/IO, NO wasm toolchain. Four pillars:

    1. LARGE + BINARY round-trip — many files + multi-MB random binary + nested
       dirs survive pack→embed→extract→unpack byte-exact, AND write_tree→disk→
       read_tree→pack byte-exact (the on-disk leg).
    2. SIGNING / tamper-evidence — a signed embedded workbook verifies; mutating
       (a) the page html, (b) the embedded zip payload, (c) stripping the
       wb-bundle block each makes verify FAIL CLOSED.
    3. AGENT EDIT LOOP — unbundle → edit a file → re-bundle (idempotent embed) →
       extract → the edit survives, no stale payload, the rest byte-exact (the
       workbook-as-managed-tree claim).
    4. MEASURE — compression ratio + single-file size on a real example tree,
       logged so the value is recorded.
  """

  alias Workbooks.Bundle

  # A throwaway tenant whose repo carries an Ed25519 signing key (Workbooks.Git).
  setup do
    tenant = "bv-#{System.unique_integer([:positive])}"
    repo = Workbooks.Git.repo_path(tenant)
    File.mkdir_p!(repo)
    Workbooks.Git.did(tenant)
    on_exit(fn -> File.rm_rf!(repo) end)
    {:ok, tenant: tenant}
  end

  # A synthesized tree: many small files, nested dirs, AND large random-binary
  # entries (incompressible — the deflate path must round-trip raw bytes exactly).
  # No top-level dotfiles / control dirs (those are correctly refused on ingress).
  defp big_tree do
    base = %{
      "README.md" => String.duplicate("workbook tree\n", 200),
      "src/main.rs" => "fn main() { println!(\"hi\"); }\n",
      "src/lib/util.rs" => String.duplicate("pub fn f() {}\n", 50),
      "src/lib/nested/deep/mod.rs" => "pub mod inner;\n",
      "data/notes.txt" => "α β γ δ — unicode\n" |> String.duplicate(100),
      "data/empty.txt" => "",
      "assets/logo.svg" => "<svg viewBox=\"0 0 10 10\"></svg>"
    }

    # Several MB of random (incompressible) binary across multiple entries +
    # one large highly-compressible entry (proves both deflate regimes).
    binaries = %{
      "blobs/rand-3mb.bin" => :crypto.strong_rand_bytes(3 * 1024 * 1024),
      "blobs/rand-1mb.bin" => :crypto.strong_rand_bytes(1 * 1024 * 1024),
      "blobs/nested/rand-512k.bin" => :crypto.strong_rand_bytes(512 * 1024),
      "blobs/zeros-2mb.bin" => :binary.copy(<<0>>, 2 * 1024 * 1024)
    }

    # Many small files to stress the central-directory walk.
    many = for i <- 1..300, into: %{}, do: {"many/f#{i}.txt", "entry-#{i}-#{:rand.uniform(99999)}\n"}

    base |> Map.merge(binaries) |> Map.merge(many)
  end

  describe "(1) LARGE + BINARY round-trip — byte-exact through every leg" do
    test "pack → embed → extract → unpack is byte-exact (in-html carrier)" do
      parts = big_tree()
      assert map_size(parts) > 300

      blob = Bundle.pack(parts)
      html = Bundle.embed("<html><body>carrier</body></html>", blob)

      assert Bundle.embedded?(html)
      out = Bundle.unpack(Bundle.extract(html))

      assert out == parts, "every entry (incl. 3MB+ random binary + 300 files) must survive byte-exact"
      # spot-assert the big binary specifically
      assert byte_size(out["blobs/rand-3mb.bin"]) == 3 * 1024 * 1024
      assert out["blobs/rand-3mb.bin"] == parts["blobs/rand-3mb.bin"]
      assert out["data/empty.txt"] == ""
    end

    test "write_tree → disk → read_tree → pack → unpack is byte-exact (the on-disk leg)" do
      parts = big_tree()
      dir = Path.join(System.tmp_dir!(), "bv-tree-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)

      written = Bundle.write_tree(parts, dir)
      assert written == map_size(parts)

      # nested dirs were materialized on disk
      assert File.regular?(Path.join(dir, "src/lib/nested/deep/mod.rs"))
      assert File.regular?(Path.join(dir, "blobs/nested/rand-512k.bin"))

      back = Bundle.read_tree(dir)
      assert back == parts, "round-trip through real disk must be byte-exact"

      # and re-packing the disk tree round-trips through the zip too
      assert Bundle.unpack(Bundle.pack(back)) == parts
    end
  end

  describe "(2) SIGNING / tamper-evidence — fail-closed on every mutation" do
    test "a signed embedded workbook verifies; (a) page (b) payload (c) strip each FAIL", %{tenant: tenant} do
      vfs = :crypto.strong_rand_bytes(64 * 1024)
      signed = Bundle.ship("wb-bv-sign", "<html><body>ORIGINAL PAGE BODY</body></html>", vfs, tenant: tenant)

      # baseline: valid
      assert Bundle.embedded?(signed)
      base = Bundle.verify(signed)
      assert base.valid, "freshly signed embedded workbook must verify: #{inspect(base)}"
      assert base.signature
      assert base.asset_integrity

      # (a) MUTATE THE PAGE HTML (outside the bundle block) → asset hash breaks
      page_mutated = String.replace(signed, "ORIGINAL PAGE BODY", "TAMPERED PAGE BODY", global: false)
      assert page_mutated != signed
      va = Bundle.verify(page_mutated)
      refute va.valid, "mutating the page html must fail verify (fail-closed)"

      # (b) MUTATE THE EMBEDDED ZIP PAYLOAD ONLY (page bytes otherwise untouched)
      evil = Bundle.pack(%{"vfs.sqlite" => "TAMPERED-VFS", "manifest.json" => "{}"})
      evil_b64 = Base.encode64(evil)

      payload_mutated =
        Regex.replace(
          ~r/(<script[^>]*id="wb-bundle"[^>]*>).*?(<\/script>)/s,
          signed,
          "\\1#{evil_b64}\\2"
        )

      assert payload_mutated != signed
      vb = Bundle.verify(payload_mutated)
      assert vb.asset_integrity, "only the bundle block changed → page asset hash still ok"
      refute vb.valid, "a swapped embedded payload must fail the wb.bundle.sha256 binding (fail-closed)"
      assert vb[:bundle_integrity] == false

      # (c) STRIP THE wb-bundle BLOCK → the carrier no longer holds its filesystem.
      # verify MUST NOT return a valid verdict. Stripping leaves a non-bundle html,
      # so verify fails-closed by REFUSING it (read_any raises) — a raise and a
      # {valid: false} map both satisfy "verify FAILS". Accept either, reject valid.
      stripped = Regex.replace(~r/<script[^>]*id="wb-bundle"[^>]*>.*?<\/script>/s, signed, "", global: true)
      refute Bundle.embedded?(stripped)

      vc_fails =
        try do
          vc = Bundle.verify(stripped)
          not vc.valid
        rescue
          ArgumentError -> true
        end

      assert vc_fails,
             "stripping the embedded payload from a signed bundle must make verify FAIL (fail-closed)"
    end

    test "sign_embedded yields the same fail-closed binding as ship", %{tenant: tenant} do
      blob = Bundle.pack(%{"vfs.sqlite" => "DATA", "manifest.json" => "{}"})
      page = Bundle.embed("<html><body>direct sign</body></html>", blob)

      signed = Bundle.sign_embedded(page, tenant)
      assert Bundle.verify(signed).valid

      # swap payload → fail
      evil = Bundle.pack(%{"vfs.sqlite" => "EVIL", "manifest.json" => "{}"})

      tampered =
        Regex.replace(
          ~r/(<script[^>]*id="wb-bundle"[^>]*>).*?(<\/script>)/s,
          signed,
          "\\1#{Base.encode64(evil)}\\2"
        )

      refute Bundle.verify(tampered).valid
    end
  end

  describe "(3) AGENT EDIT LOOP — workbook-as-managed-tree, no stale payload" do
    test "unbundle → edit one file → re-bundle (idempotent) → edit survives, rest byte-exact" do
      parts = big_tree()
      blob = Bundle.pack(parts)
      html = Bundle.embed("<html><body>v1</body></html>", blob)

      # --- unbundle (extract → unpack the managed tree) ---
      tree = Bundle.unpack(Bundle.extract(html))
      assert tree == parts

      # --- agent edits exactly one file (and leaves everything else alone) ---
      edited = Map.put(tree, "src/main.rs", "fn main() { println!(\"EDITED\"); }\n")

      # --- re-bundle: embed is idempotent; the prior payload must NOT stack ---
      new_blob = Bundle.pack(edited)
      rebundled = Bundle.embed(html, new_blob)

      # exactly ONE wb-bundle block remains (no stale payload accreted)
      assert length(Regex.scan(~r/id="wb-bundle"/, rebundled)) == 1

      # --- extract → the edit survived, the rest is byte-exact ---
      out = Bundle.unpack(Bundle.extract(rebundled))
      assert out["src/main.rs"] =~ "EDITED"
      assert out == edited

      # the unchanged large binary is still byte-identical after the loop
      assert out["blobs/rand-3mb.bin"] == parts["blobs/rand-3mb.bin"]

      # and the OLD content is genuinely gone (no stale payload leaking through)
      refute out["src/main.rs"] =~ "\"hi\""
    end

    test "the disk edit loop survives too (write_tree → edit on disk → read_tree)" do
      parts = big_tree()
      dir = Path.join(System.tmp_dir!(), "bv-edit-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)

      Bundle.write_tree(parts, dir)
      # agent edits a file directly on the managed tree
      File.write!(Path.join(dir, "data/notes.txt"), "REWRITTEN ON DISK\n")

      back = Bundle.read_tree(dir)
      assert back["data/notes.txt"] == "REWRITTEN ON DISK\n"
      # everything else byte-exact
      assert Map.delete(back, "data/notes.txt") == Map.delete(parts, "data/notes.txt")
    end
  end

  describe "(4) MEASURE — compression ratio + single-file size on a real tree" do
    test "log the value: a real source tree packs to one signed .html" do
      # A real example tree shipped in-repo (the host source — source-heavy ⇒ high
      # deflate ratio). Hermetic: just reads files + zips, no toolchain.
      real_dir = Path.expand(Path.join(__DIR__, "../host"))
      assert File.dir?(real_dir)

      parts = Bundle.read_tree(real_dir)
      file_count = map_size(parts)
      raw_bytes = parts |> Map.values() |> Enum.map(&byte_size/1) |> Enum.sum()

      blob = Bundle.pack(parts)
      packed_bytes = byte_size(blob)

      # the single self-contained file: page + embedded (base64) bundle
      html = Bundle.embed("<html><body>real tree</body></html>", blob)
      single_file_bytes = byte_size(html)

      ratio = raw_bytes / max(packed_bytes, 1)
      b64_overhead = single_file_bytes / max(packed_bytes, 1)

      msg = """

      ── bundle compression — real tree (runtime/host) ──────────────────
        files                : #{file_count}
        raw (uncompressed)   : #{fmt(raw_bytes)}
        packed zip           : #{fmt(packed_bytes)}
        compression ratio    : #{Float.round(ratio, 2)}× (#{Float.round((1 - packed_bytes / raw_bytes) * 100, 1)}% smaller)
        single .html file    : #{fmt(single_file_bytes)}  (base64 overhead #{Float.round(b64_overhead, 2)}×)
      ───────────────────────────────────────────────────────────────────
      """

      IO.puts(msg)

      # round-trips byte-exact even at this scale
      assert Bundle.unpack(Bundle.extract(html)) == parts
      assert ratio > 1.0, "a source tree must actually compress"

      # record numbers as a test artifact too
      File.write!(
        Path.join(System.tmp_dir!(), "bundle-validation-measure.txt"),
        msg
      )
    end
  end

  defp fmt(bytes) when bytes >= 1024 * 1024, do: "#{Float.round(bytes / 1024 / 1024, 2)} MB"
  defp fmt(bytes) when bytes >= 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp fmt(bytes), do: "#{bytes} B"
end
