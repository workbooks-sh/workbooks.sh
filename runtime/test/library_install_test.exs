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
end
