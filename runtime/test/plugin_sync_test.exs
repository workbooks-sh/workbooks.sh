defmodule Workbooks.PluginSyncTest do
  @moduledoc """
  wb-39j.4 — the federation sync daemon. Pulls a data source and mirrors its rows
  into :task: org nodes in the VFS (the resident, queryable local face).
  """
  use ExUnit.Case, async: false

  alias Workbooks.{DataSource, VFS, Plugin}

  test "pull_once mirrors a source's rows into :task: org in the VFS" do
    {:ok, vfs} = VFS.open(":memory:")

    DataSource.register("sync-item", Workbooks.DataSource.Http, %{"url" => "https://x"})
    stub = fn _u, _h -> {:ok, ~s|[{"id":1,"title":"alpha"},{"id":2,"title":"beta"}]|} end

    assert {:ok, 2, org} = Plugin.Sync.pull_once("sync-item", vfs: vfs, path: "sync/items.org", http: stub)

    # rendered as :task: headlines with property drawers
    assert org =~ "* alpha :task:"
    assert org =~ "* beta :task:"
    assert org =~ ":ID: 1"

    # actually written to the VFS (the resident mirror the agent reads)
    assert {:ok, written} = VFS.get(vfs, "sync/items.org")
    assert written =~ "beta"
  end

  test "pull_once on a non-data-source entity errors clearly" do
    assert {:error, {:not_a_data_source, "no-such"}} = Plugin.Sync.pull_once("no-such")
  end

  test "the daemon starts and is supervised (no immediate pull)" do
    # interval far in the future → starts cleanly without pulling during the test
    DataSource.register("d-item", Workbooks.DataSource.Http, %{"url" => "https://x"})
    {:ok, pid} = Plugin.Sync.start_link(entity: "d-item", interval_ms: 600_000)
    assert Process.alive?(pid)
    GenServer.stop(pid)
  end
end
