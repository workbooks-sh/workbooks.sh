defmodule Nexus.Agent.KitsTest do
  use ExUnit.Case, async: false
  alias Nexus.Agent.Kits

  test "the core catalog always has coreutils + web" do
    all = Kits.all()
    assert Map.has_key?(all, "coreutils")
    assert Map.has_key?(all, "web")
    assert Kits.summary() =~ "coreutils"
  end

  test "coreutils applets resolve to the coreutils wasm with the applet as first arg" do
    {wasm, ["ls"]} = Kits.resolve("ls")
    assert wasm =~ "coreutils.wasm"
  end

  test "an unknown command resolves to nil" do
    assert Kits.resolve("definitely-not-a-command") == nil
  end

  test "an external kit registers from a .kit manifest (summary + commands)" do
    root = Kits.root()
    File.mkdir_p!(root)
    File.write!(Path.join(root, "demo.wasm"), "fake")
    File.write!(Path.join(root, "demo.kit"), "a demo kit\ndemo run build")
    on_exit(fn -> File.rm(Path.join(root, "demo.wasm")); File.rm(Path.join(root, "demo.kit")) end)

    k = Kits.all()["demo"]
    assert k.summary == "a demo kit"
    assert k.commands == ["demo", "run", "build"]
    assert Kits.help("demo") =~ "run build"
    # resolve a manifest command to the kit's wasm
    {wasm, []} = Kits.resolve("demo")
    assert wasm =~ "demo.wasm"
  end
end
