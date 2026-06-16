defmodule Workbooks.KernelDispatchTest do
  @moduledoc """
  wb-pkh.11 — a toolkit declares #+EXEC: kernel and `work toolkit build` produces a
  bytes→bytes reactor, registered in KernelRegistry and opened by name (the
  manifest-declaration convenience over the wb-pkh.1 source→kernel recipe).
  """
  use ExUnit.Case, async: false

  alias Workbooks.{Toolkits, KernelRegistry, Kernel}

  @kernel_c File.read!(Path.join(__DIR__, "fixtures/kernel/reverse.c"))

  defp write_kernel_toolkit(root, name) do
    dir = Path.join(root, name)
    File.mkdir_p!(Path.join(dir, "src"))
    File.mkdir_p!(Path.join(dir, "skills"))
    File.write!(Path.join(dir, "src/reverse.c"), @kernel_c)
    File.write!(Path.join(dir, "skills/overview.org"), "#+TITLE: #{name}\n* When to use this\nx\n")

    File.write!(Path.join(dir, "manifest.org"), """
    #+TITLE: #{name}
    #+TOOLKIT: #{name}
    #+VERSION: 0.1.0
    #+EXEC: kernel
    #+CLI_BIN: #{name}
    #+BUILD_LANG: c
    #+BUILD_SRC: path:src

    * #{name} :toolkit:
    :PROPERTIES:
    :ID: #{name}
    :END:
    body
    """)

    dir
  end

  @tag :build
  test "work toolkit build of an #+EXEC: kernel toolkit → registered kernel → open by name → run" do
    root = Path.join(System.tmp_dir!(), "wb-kdisp-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    name = "kr#{System.unique_integer([:positive])}"
    write_kernel_toolkit(root, name)

    prev = System.get_env("WB_TOOLKITS_ROOT")
    System.put_env("WB_TOOLKITS_ROOT", root)

    try do
      out = Toolkits.build_text(name)
      assert out =~ "registered kernel"
      assert name in KernelRegistry.list()

      # Open the registered kernel by name and run it (compiled → arena :exports).
      assert {:ok, k} = Kernel.open_named(name, arena: :exports)
      assert {:ok, "cba"} = Kernel.call(k, "abc")
      assert {:ok, "olleh"} = Kernel.call(k, "hello")
      Kernel.close(k)
    after
      if prev, do: System.put_env("WB_TOOLKITS_ROOT", prev), else: System.delete_env("WB_TOOLKITS_ROOT")
    end
  end

  test "open_named on an unknown kernel errors cleanly" do
    assert {:error, {:no_such_kernel, "nope_xyz"}} = Kernel.open_named("nope_xyz")
  end

  test "KernelRegistry rejects a bad name" do
    assert {:error, :invalid_name} = KernelRegistry.register("../evil", "/tmp/x.wasm")
  end
end
