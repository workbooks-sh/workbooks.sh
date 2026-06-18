defmodule Nexus.SandboxTest do
  use ExUnit.Case, async: false

  # Proves the whole sandbox path is real: a wasm component (built here with wasm-tools, the
  # same toolchain the compilers emit into) instantiates and runs on wasmex via Nexus.Sandbox,
  # with typed marshalling (core i32 → WIT s32 → Elixir 42). Skips if wasm-tools is absent.
  test "Nexus.Sandbox runs a wasm component on wasmex, with typed return" do
    unless System.find_executable("wasm-tools") and System.find_executable("wasmtime") do
      :ok
    else
      dir = Path.join(System.tmp_dir!(), "nxsbx_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      core = Path.join(dir, "c.core.wasm")
      embed = Path.join(dir, "c.embed.wasm")
      comp = Path.join(dir, "thing.component.wasm")
      wat = Path.join(dir, "c.wat")
      wit = Path.join(dir, "w.wit")

      File.write!(wat, ~s|(module (func (export "run") (result i32) (i32.const 42)))|)
      File.write!(wit, "package nexus:test;\nworld thing {\n  export run: func() -> s32;\n}\n")

      {_, 0} = System.cmd("wasm-tools", ["parse", wat, "-o", core])
      {_, 0} = System.cmd("wasm-tools", ["component", "embed", wit, core, "--world", "thing", "-o", embed])
      {_, 0} = System.cmd("wasm-tools", ["component", "new", embed, "-o", comp])

      {:ok, pid} = Nexus.Sandbox.start(comp, [])
      assert {:ok, 42} = Nexus.Sandbox.call(pid, "run", [])

      File.rm_rf!(dir)
    end
  end
end
