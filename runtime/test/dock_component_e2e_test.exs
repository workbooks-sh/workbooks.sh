defmodule Workbooks.DockComponentE2ETest do
  @moduledoc """
  wb-pkh.12 — the capstone: a REAL component (cargo-component) that reaches the Dock
  through the dock SDK wrapper (dock::command::run, via dock::bind!(bindings, command))
  runs through an Instance. Proves the SDK macro + cap wrapper + run-command Dock
  import work end to end in actual WASM, not just unit stubs.
  """
  use ExUnit.Case, async: false
  alias Workbooks.Instance

  @fixture "build/fixtures/engine-dock-probe.wasm"

  test "dock::command::run through a real component → run-command Dock → upper command" do
    bytes = File.read!(@fixture)
    id = "dockc-#{System.unique_integer([:positive])}"
    {:ok, _} = Instance.Supervisor.start_instance(id, bytes, policy: :minimal)
    on_exit(fn -> Instance.Supervisor.stop_instance(id) end)

    # The component's run() calls dock::command::run("upper", input, []) — the SDK
    # wrapper → run-command Dock import → the `upper` builtin → uppercased stdout.
    assert {:ok, "HELLO WORLD"} = Instance.call(id, "run", ["hello world"])
    assert {:ok, "ABC"} = Instance.call(id, "run", ["abc"])
  end
end
