defmodule Workbooks.LibraryInstallTest do
  @moduledoc """
  wb-rhs.7 — the toolkit "registry" is just the workbook rails. A toolkit is a
  workbook (still an HTML/.wbundle artifact like every other); the one new verb is
  Library.install/2 — register the compiled command artifacts a bundle carries,
  with an install-by-sha supply-chain pin. These tests exercise that verb directly.
  """
  use ExUnit.Case, async: false

  alias Workbooks.{Library, Bundle, CommandRegistry}

  defp uniq(p), do: "#{p}_#{System.unique_integer([:positive])}"

  # A Javy JS command that reverses stdin — built once, reused as the .wasm part a
  # toolkit-workbook would carry.
  @rev_src ~S|const CH=65536;const cs=[];let n;const b=new Uint8Array(CH);while((n=Javy.IO.readSync(0,b))>0){cs.push(b.slice(0,n));}let t=0;for(const c of cs)t+=c.length;const all=new Uint8Array(t);let o=0;for(const c of cs){all.set(c,o);o+=c.length;}const s=new TextDecoder().decode(all).trim();Javy.IO.writeSync(1,new TextEncoder().encode(s.split("").reverse().join("")));|

  defp rev_wasm_bytes do
    name = uniq("seed")
    {:ok, path} = CommandRegistry.build_and_register_inline(name, "js", @rev_src)
    File.read!(path)
  end

  @tag :build
  test "install registers a bundle's .wasm command → run-command finds it" do
    bytes = rev_wasm_bytes()
    cmd = uniq("rev")
    # A toolkit-workbook carries its compiled command as a <name>.wasm part — same
    # shape pack(build: true) produces. (It's still just a .wbundle of an HTML
    # workbook; here we pack the one part the verb cares about.)
    blob = Bundle.pack(%{"#{cmd}.wasm" => bytes})

    assert {:ok, %{commands: [^cmd]}} = Library.install(blob)
    assert cmd in CommandRegistry.list()
    assert {:ok, "cba"} = CommandRegistry.run(cmd, "abc")
  end

  @tag :build
  test "install-by-sha pin: wrong sha refuses, correct sha installs" do
    bytes = rev_wasm_bytes()
    cmd = uniq("pin")
    blob = Bundle.pack(%{"#{cmd}.wasm" => bytes})
    good = :crypto.hash(:sha256, blob) |> Base.encode16(case: :lower)

    # A tampered/incorrect pin is refused BEFORE anything is registered.
    assert {:error, :sha_mismatch} = Library.install(blob, sha: "deadbeef")
    refute cmd in CommandRegistry.list()

    # The correct content address passes the gate.
    assert {:ok, %{commands: [^cmd]}} = Library.install(blob, sha: good)
    assert {:ok, "cba"} = CommandRegistry.run(cmd, "abc")
  end

  test "install of a bundle with no commands is a clean no-op" do
    blob = Bundle.pack(%{"workbook.html" => "<html><body>just a doc</body></html>"})
    assert {:ok, %{commands: []}} = Library.install(blob)
  end

  @tag :build
  test "REALISTIC workbook bundle: built artifact + html/vfs/manifest parts → install picks the .wasm, ignores the rest" do
    # A real .wbundle is workbook.html + vfs.sqlite + manifest.json + the compiled
    # <name>.wasm parts (build projection). Earlier tests packed a lone .wasm; this
    # one mirrors the actual ship/pack shape and proves install ignores non-wasm
    # parts and registers the BUILT command.
    bytes = rev_wasm_bytes()
    cmd = uniq("rev")

    parts = %{
      "workbook.html" =>
        ~s|<html><script id="workbook-spec">{"toolkit":"#{cmd}"}</script><body>doc</body></html>|,
      "vfs.sqlite" => <<0x53, 0x51, 0x4C, 0x69, 0x74, 0x65, 0, 0>>,
      "manifest.json" => Jason.encode!(%{"id" => cmd, "format" => "wbundle/1", "signed" => false}),
      "#{cmd}.wasm" => bytes
    }

    blob = Bundle.pack(parts)
    assert {:ok, %{commands: [^cmd]}} = Library.install(blob)
    assert {:ok, "cba"} = CommandRegistry.run(cmd, "abc")
  end

  @tag :build
  test "store → fetch → install: the distribution chain via Storage" do
    # The publish/install round-trip end to end: a built toolkit bundle is STORED
    # (Storage.put, the registry backend), FETCHED by key (Library.fetch), then
    # INSTALLED and run. This is wb-pkh.3's chain minus the workspace-pack front
    # (Library.pack, which produces the bundle and is its own concern).
    bytes = rev_wasm_bytes()
    cmd = uniq("rev")
    blob = Bundle.pack(%{"#{cmd}.wasm" => bytes})
    tenant = "wbtest_#{System.unique_integer([:positive])}"
    key = "workbooks/#{cmd}.wbundle"

    assert :ok = Workbooks.Storage.put(tenant, key, blob)
    assert {:ok, fetched} = Workbooks.Library.fetch(tenant, key)
    assert fetched == blob
    assert {:ok, %{commands: [^cmd]}} = Library.install(fetched)
    assert {:ok, "cba"} = CommandRegistry.run(cmd, "abc")

    Workbooks.Storage.delete(tenant, key)
  end

  @tag :build
  test "install round-trips through unpack — the bundle is a plain zip any tool reads" do
    # Sanity that what install consumes is the same portable .wbundle the rest of
    # the system produces: pack → unpack returns the parts verbatim, and install
    # on the packed blob registers the command. (No bespoke install format.)
    bytes = rev_wasm_bytes()
    cmd = uniq("rev")
    blob = Bundle.pack(%{"#{cmd}.wasm" => bytes, "readme.txt" => "hi"})

    parts = Bundle.unpack(blob)
    assert Map.has_key?(parts, "#{cmd}.wasm")
    assert parts["readme.txt"] == "hi"

    assert {:ok, %{commands: [^cmd]}} = Library.install(blob)
    assert {:ok, "cba"} = CommandRegistry.run(cmd, "abc")
  end

  @tag :build
  test "signed third-party install: valid signature passes, tampered is rejected" do
    # wb-pkh.9: a signed toolkit-workbook installs only when its embedded signature
    # verifies (require_signature: true — the third-party trust posture).
    prev = System.get_env("WB_DATA")
    data = Path.join(System.tmp_dir!(), "wbdata-#{System.unique_integer([:positive])}")
    System.put_env("WB_DATA", data)

    try do
      tenant = "signer-#{System.unique_integer([:positive])}"
      Workbooks.Git.ensure_repo(tenant)

      bytes = rev_wasm_bytes()
      cmd = uniq("rev")
      html = Workbooks.Manifest.sign(~s|<html><script id="workbook-spec">{"toolkit":"#{cmd}"}</script><body>x</body></html>|, tenant)

      blob = Bundle.pack(%{"workbook.html" => html, "#{cmd}.wasm" => bytes})
      assert {:ok, %{commands: [^cmd]}} = Library.install(blob, require_signature: true)
      assert {:ok, "cba"} = CommandRegistry.run(cmd, "abc")

      # Tamper the signed HTML (append content → strip() differs → asset_integrity
      # fails) → rejected, and nothing new is registered.
      cmd2 = uniq("rev")
      tampered = html <> "<!--tampered-after-signing-->"
      bad = Bundle.pack(%{"workbook.html" => tampered, "#{cmd2}.wasm" => bytes})
      assert {:error, {:bad_signature, _}} = Library.install(bad, require_signature: true)
      refute cmd2 in CommandRegistry.list()
    after
      if prev, do: System.put_env("WB_DATA", prev), else: System.delete_env("WB_DATA")
    end
  end

  @tag :build
  test "require_signature on an UNSIGNED bundle is rejected" do
    bytes = rev_wasm_bytes()
    cmd = uniq("rev")
    blob = Bundle.pack(%{"#{cmd}.wasm" => bytes})
    assert {:error, {:unverifiable, _}} = Library.install(blob, require_signature: true)
    refute cmd in CommandRegistry.list()
  end
end

