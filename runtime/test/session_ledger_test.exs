defmodule Workbooks.SessionLedgerTest do
  @moduledoc """
  The append-only session ledger backs the desktop's chat-history list
  (wb-kbq5 / wb-t3mr). Isolated via WB_DATA → a fresh temp dir, so these don't
  touch the real ledger. A session no longer registered as a live AgentSession
  is treated as completed (the common case for browsing past chats).
  """
  use ExUnit.Case, async: false

  alias Workbooks.SessionLedger

  setup do
    prev = System.get_env("WB_DATA")
    dir = Path.join(System.tmp_dir!(), "wb-ledger-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    System.put_env("WB_DATA", dir)

    on_exit(fn ->
      if prev, do: System.put_env("WB_DATA", prev), else: System.delete_env("WB_DATA")
      File.rm_rf(dir)
    end)

    :ok
  end

  test "record → list round-trips, newest first, as completed (no live session)" do
    SessionLedger.record("run-1", "waldo", "first prompt", "/wd")
    SessionLedger.record("run-2", "scout", "second prompt", "/wd")

    rows = SessionLedger.list()
    assert length(rows) == 2
    # newest first
    assert [%{session_id: "run-2"}, %{session_id: "run-1"}] = rows
    assert hd(rows).agent_slug == "scout"
    assert hd(rows).prompt_preview == "second prompt"
    # unregistered → completed (folded at read time)
    assert Enum.all?(rows, &(&1.status == "completed"))
  end

  test "prompt_preview is truncated to 120 chars" do
    long = String.duplicate("x", 300)
    SessionLedger.record("run-long", "waldo", long, nil)
    [row] = SessionLedger.list()
    assert String.length(row.prompt_preview) == 120
  end

  test "active_only? filters out completed runs (none live → empty)" do
    SessionLedger.record("run-done", "waldo", "done one", "/wd")
    assert SessionLedger.list(true) == []
    # but the unfiltered list still has it
    assert length(SessionLedger.list()) == 1
  end

  test "record is best-effort and list is resilient to a malformed line" do
    SessionLedger.record("run-ok", "waldo", "ok", "/wd")
    # append a corrupt line directly
    File.write!(Path.join(System.get_env("WB_DATA"), "wb-sessions.jsonl"), "{not json\n", [:append])
    rows = SessionLedger.list()
    # the good entry survives; the bad line is dropped, not crashed
    assert Enum.any?(rows, &(&1.session_id == "run-ok"))
  end

  test "empty/absent ledger lists nothing (no crash)" do
    assert SessionLedger.list() == []
  end

  test "dedupe keeps a single row per session_id" do
    SessionLedger.record("dup", "waldo", "v1", "/wd")
    SessionLedger.record("dup", "waldo", "v2", "/wd")
    rows = SessionLedger.list()
    assert Enum.count(rows, &(&1.session_id == "dup")) == 1
  end
end
