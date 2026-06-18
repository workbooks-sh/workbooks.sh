defmodule Workbooks.WitComponentizeTest do
  use ExUnit.Case, async: true
  alias Workbooks.Wit

  setup do
    dir = Path.join(System.tmp_dir!(), "wbcz_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "componentize binds a generated world to a core module → a valid component", %{dir: dir} do
    if System.find_executable("wasm-tools") do
      # a minimal core module exporting `run`, matching the world below
      wat = Path.join(dir, "core.wat")
      core = Path.join(dir, "core.wasm")
      File.write!(wat, ~s|(module (func (export "run")))|)
      assert {_, 0} = System.cmd("wasm-tools", ["parse", wat, "-o", core], stderr_to_stdout: true)

      world = "package work:u;\nworld u {\n  export run: func();\n}\n"
      out = Path.join(dir, "comp.wasm")

      assert {:ok, ^out} = Wit.componentize(core, world, "u", out)
      assert File.regular?(out)

      # the produced artifact is a valid Component-Model component
      {_, code} = System.cmd("wasm-tools", ["validate", out], stderr_to_stdout: true)
      assert code == 0
    end
  end

  test "componentize reports an error when the core doesn't satisfy the world", %{dir: dir} do
    if System.find_executable("wasm-tools") do
      wat = Path.join(dir, "empty.wat")
      core = Path.join(dir, "empty.wasm")
      File.write!(wat, "(module)")
      assert {_, 0} = System.cmd("wasm-tools", ["parse", wat, "-o", core], stderr_to_stdout: true)

      # world demands an export the empty core can't provide
      world = "package work:u;\nworld u {\n  export run: func();\n}\n"
      assert {:error, _msg} = Wit.componentize(core, world, "u", Path.join(dir, "c.wasm"))
    end
  end
end
