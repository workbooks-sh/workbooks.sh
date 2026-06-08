defmodule Workbooks.NativeFreeTest do
  @moduledoc """
  wb-fm0.8 — prove the untrusted-source path is native-compiler-free.

  Two guards:
  1. STATIC: package_manager.ex contains no `Workbooks.Sandbox.run` (the old native-compile
     boundary) — every language lane routes through the in-sandbox Compilers/yaegi/QuickJS.
  2. FUNCTIONAL: componentize + validate run IN the sandbox (wasm-tools.wasm under wasmtime),
     no native wasm-tools binary. (The 6 language lanes themselves are covered by stress_test.)
  """
  use ExUnit.Case, async: false
  alias Workbooks.PackageManager, as: PM

  test "no native Sandbox.run compile calls remain in package_manager (the canon)" do
    src = File.read!(Path.expand("../host/package_manager.ex", __DIR__))
    refute src =~ "Sandbox.run", "untrusted source must not compile via Workbooks.Sandbox (native)"
    # the only remaining native System.cmd are: trusted provisioning (bash build.sh) + the
    # carved-out component tooling (wac, jco). None compile untrusted SOURCE.
    refute src =~ ~r/System\.cmd\(\s*"cargo"/, "no native cargo"
    refute src =~ ~r/System\.cmd\(\s*"tinygo"/, "no native tinygo"
    refute src =~ ~r/System\.cmd\(\s*@javy/, "no native javy"
  end

  @tag :build
  @tag timeout: 300_000
  test "componentize + validate run in-sandbox via wasm-tools.wasm (no native wasm-tools)" do
    src = ~S|Javy.IO.writeSync(1, new TextEncoder().encode("ok\n"));|
    {_n, "js", {:ok, core, _}} = PM.build(%{"name" => "nf", "lang" => "js", "src" => src})
    assert {:ok, comp, how} = PM.componentize(core)
    assert how in [:built, :cached]
    assert PM.validate_component(comp) == :valid
  end
end
