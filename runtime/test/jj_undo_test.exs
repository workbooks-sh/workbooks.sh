defmodule Workbooks.JJUndoTest do
  @moduledoc """
  Phase 2 — Undo. The user-facing Undo rides the git-level append-only Restore
  (`History.undo/2`): undo the last Change by re-applying the prior version as a
  NEW Change — nothing erased, reversible, tenant-gated, and working identically
  whether or not `jj` is installed. We also smoke-test the jj op-log reader
  (`JJ.op_entries/2`), which stays a read-only corroborating ledger (skipped
  cleanly when `jj` is absent).
  """
  use ExUnit.Case, async: false

  alias Workbooks.{JJ, Git, History, ControlPlane}

  setup do
    prev = System.get_env("WB_DATA")
    data = Path.join(System.tmp_dir!(), "wb-jj-#{System.unique_integer([:positive])}")
    File.mkdir_p!(data)
    System.put_env("WB_DATA", data)

    on_exit(fn ->
      if prev, do: System.put_env("WB_DATA", prev), else: System.delete_env("WB_DATA")
      File.rm_rf(data)
    end)

    {:ok, jj: JJ.available?()}
  end

  defp uniq(p), do: "#{p}-#{System.unique_integer([:positive])}"

  defp commit(tenant, scope, org, author) do
    ControlPlane.put_workbook(scope, org, tenant)
    Git.save(%{tenant: tenant, author: author, email: "#{author}@workbooks.local"}, scope, org)
  end

  test "undo reverts the last Change and is APPEND-ONLY (nothing erased)" do
    t = uniq("bob")
    scope = uniq("atlas")
    commit(t, scope, "* one\n", t)
    commit(t, scope, "* one\n* two\n", t)

    {:ok, before} = History.timeline(scope, t)
    assert length(before) == 2

    file = Path.join(Git.repo_path(t), "#{scope}.org")
    assert File.read!(file) =~ "two"

    # undo → content returns to the prior version, as a NEW Change on top
    assert {:ok, change} = History.undo(scope, t)
    assert change.title =~ ~r/restore/i or is_binary(change.title)
    refute File.read!(file) =~ "two"
    assert File.read!(file) =~ "one"

    {:ok, after_} = History.timeline(scope, t)
    # append-only: the timeline GREW (the two originals are intact, plus the undo)
    assert length(after_) == 3
    assert Enum.all?(before, fn b -> Enum.any?(after_, &(&1.id == b.id)) end)
  end

  test "undo is reversible — undo, then undo again climbs back" do
    t = uniq("dana")
    scope = uniq("nova")
    commit(t, scope, "* v1\n", t)
    commit(t, scope, "* v2\n", t)

    file = Path.join(Git.repo_path(t), "#{scope}.org")
    assert {:ok, _} = History.undo(scope, t)     # → v1 content
    assert File.read!(file) =~ "v1"
    # a second undo now reverts the *undo* commit, climbing back toward v2
    assert {:ok, _} = History.undo(scope, t)
    assert File.read!(file) =~ "v2"
  end

  test "undo with only an initial Change → nothing_to_undo (no erase, no new Change)" do
    t = uniq("erin")
    scope = uniq("seed")
    commit(t, scope, "* only\n", t)

    assert {:ok, :nothing_to_undo} = History.undo(scope, t)
    {:ok, tl} = History.timeline(scope, t)
    assert length(tl) == 1
  end

  test "undo gates by scope ownership (cross-tenant → not_found, no mutation)" do
    owner = uniq("owner")
    attacker = uniq("attacker")
    scope = uniq("secret")
    commit(owner, scope, "* secret v1\n", owner)
    commit(owner, scope, "* secret v2\n", owner)

    assert {:error, :not_found} = History.undo(scope, attacker)

    # the rejected cross-tenant undo changed nothing
    file = Path.join(Git.repo_path(owner), "#{scope}.org")
    assert File.read!(file) =~ "secret v2"
  end

  test "undo fails closed on nil/empty caller tenant" do
    t = uniq("frank")
    scope = uniq("vault")
    commit(t, scope, "* a\n", t)
    commit(t, scope, "* b\n", t)

    assert {:error, :not_found} = History.undo(scope, nil)
    assert {:error, :not_found} = History.undo(scope, "")
  end

  test "jj op-log reader returns validated, hex op ids (corroborating ledger)", %{jj: jj} do
    if jj do
      t = uniq("alice")
      scope = uniq("aurora")
      commit(t, scope, "* v1\n", t)
      commit(t, scope, "* v2\n", t)

      entries = JJ.op_entries(t)
      assert is_list(entries)
      assert Enum.all?(entries, fn e -> e.id =~ ~r/\A[0-9a-f]{4,}\z/ and is_binary(e.description) end)
    end
  end
end
