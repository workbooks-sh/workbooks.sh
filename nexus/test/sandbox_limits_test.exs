defmodule Nexus.SandboxLimitsTest do
  use ExUnit.Case, async: true

  # wb-9jqy — every untrusted component must instantiate with a POPULATED StoreLimits (a bounded
  # memory/table/instance ceiling), not wasmtime's unlimited default that lets one guest OOM-kill the
  # whole nexus. These assert the limit is wired and non-unlimited, sourced from Nexus.Config.

  test "store_limits is populated (memory capped, single instance/memory/table)" do
    l = Nexus.Sandbox.store_limits()
    assert is_integer(l.memory_size) and l.memory_size > 0
    assert l.memory_size == Nexus.Config.sandbox_memory_mb() * 1024 * 1024
    assert l.instances == Nexus.Config.sandbox_max_instances()
    assert l.memories == Nexus.Config.sandbox_max_instances()
    assert l.tables == Nexus.Config.sandbox_max_instances()
    assert l.table_elements == Nexus.Config.sandbox_table_elements()
  end

  test "Config exposes neutral safe sandbox defaults" do
    assert Nexus.Config.sandbox_memory_mb() == 256
    assert Nexus.Config.sandbox_epoch_secs() == 5
    assert Nexus.Config.sandbox_table_elements() == 100_000
    assert Nexus.Config.sandbox_max_instances() == 32
  end

  test "compile/proc-macro subprocess caps (wb-3f42): generous memory + bounded fan-out lane" do
    # compiles need GBs of working set, so a larger cap than the command lane (256 MiB) — but bounded.
    assert Nexus.Config.sandbox_compile_memory_mb() == 3072
    assert Nexus.Config.subproc_concurrency() == System.schedulers_online()
    # the :subproc gate lane is live (proc-macro/build-script fan-out runs under it).
    assert %{limit: l, in_use: _, queued: _} = Nexus.Wasm.Gate.stats(:subproc)
    assert l == System.schedulers_online()
  end
end
