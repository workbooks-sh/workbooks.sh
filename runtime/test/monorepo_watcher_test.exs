defmodule Workbooks.MonorepoWatcherTest do
  @moduledoc """
  The runtime half of the agent-file → sidebar SYNC chain (wb-9s6v). The desktop
  scopes its workspace folders, this watcher polls them and pushes `file_changed`
  over `monorepo:watch`, and the desktop sidebar (now) refreshes on that push +
  re-scans (scan_workbooks). Here we prove the watcher actually emits the push a
  NEW agent-written file produces — and, adversarially, that it stays SILENT when
  nothing changed (so it can't spam the sidebar into refresh storms).
  """
  use ExUnit.Case, async: false
  alias Workbooks.MonorepoWatcher

  setup do
    # The app boot already starts the Registry + watcher; start only if absent.
    ensure_started({Registry, keys: :duplicate, name: Workbooks.MonorepoWatch.Registry})
    ensure_started(MonorepoWatcher)
    assert Process.whereis(MonorepoWatcher), "MonorepoWatcher must be running for this test"
    dir = Path.join(System.tmp_dir!(), "wb_mw_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp ensure_started(spec) do
    case start_supervised(spec) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, {{:already_started, _}, _}} -> :ok
      _ -> :ok
    end
  end

  # :sys.get_state flushes the mailbox up to it, so the set_scope CAST (baseline)
  # is guaranteed processed before we mutate the dir.
  defp flush, do: :sys.get_state(MonorepoWatcher)
  defp poll, do: send(Process.whereis(MonorepoWatcher), :poll)

  test "a NEW file under the watched scope pushes file_changed:created to subscribers", %{dir: dir} do
    MonorepoWatcher.set_scope([dir])
    flush()
    MonorepoWatcher.register("jr-test")

    path = Path.join(dir, "launch-plan.html")
    File.write!(path, ~s(<html><script id="workbook-spec">{"title":"x"}</script></html>))
    poll()

    assert_receive {:channel_push, "jr-test", "monorepo:watch", "file_changed", payload}, 2_000
    assert payload["kind"] == "created"
    assert payload["path"] == path
  end

  test "deleting a watched file pushes file_changed:removed", %{dir: dir} do
    path = Path.join(dir, "gone.html")
    File.write!(path, "x")
    MonorepoWatcher.set_scope([dir])
    flush()
    MonorepoWatcher.register("jr-test")

    File.rm!(path)
    poll()

    assert_receive {:channel_push, "jr-test", "monorepo:watch", "file_changed", payload}, 2_000
    assert payload["kind"] == "removed"
    assert payload["path"] == path
  end

  test "NO spurious push when nothing changed (won't storm the sidebar)", %{dir: dir} do
    File.write!(Path.join(dir, "stable.html"), "x")
    MonorepoWatcher.set_scope([dir])
    flush()
    MonorepoWatcher.register("jr-test")

    poll()
    refute_receive {:channel_push, _, _, "file_changed", _}, 300
  end
end
