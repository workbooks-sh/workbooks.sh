defmodule Workbooks.HistoryTest do
  @moduledoc """
  Phase 1 — History + Restore. Asserts the tenant-gated timeline/diff, the
  human-vs-agent attribution heuristic, the wb-g1yo.10 confinement (a scope is an
  owned workbook id, never a path / another tenant's repo), and — the headline
  promise — that Restore is APPEND-ONLY: it adds a new Change and erases nothing.

  Uses the app-started ControlPlane (ownership index) + a fresh per-test WB_DATA
  git repo. No network.
  """
  use ExUnit.Case, async: false

  alias Workbooks.{History, Git, ControlPlane}

  setup do
    prev = System.get_env("WB_DATA")
    data = Path.join(System.tmp_dir!(), "wb-hist-#{System.unique_integer([:positive])}")
    File.mkdir_p!(data)
    System.put_env("WB_DATA", data)
    on_exit(fn ->
      if prev, do: System.put_env("WB_DATA", prev), else: System.delete_env("WB_DATA")
      File.rm_rf(data)
    end)
    :ok
  end

  # Register ownership + write a version into the tenant's git repo as `author`.
  defp commit(tenant, scope, org, author) do
    ControlPlane.put_workbook(scope, org, tenant)
    Git.save(%{tenant: tenant, author: author, email: "#{author}@workbooks.local"}, scope, org)
  end

  defp uniq(p), do: "#{p}-#{System.unique_integer([:positive])}"

  test "timeline lists Changes (newest-first) for an owned scope" do
    t = uniq("alice")
    scope = uniq("aurora")
    commit(t, scope, "* v1\n", t)
    commit(t, scope, "* v2\n", t)
    commit(t, scope, "* v3\n", t)

    assert {:ok, changes} = History.timeline(scope, t)
    assert length(changes) == 3
    # newest-first: timestamps are non-increasing
    whens = Enum.map(changes, & &1.when)
    assert whens == Enum.sort(whens, :desc)

    # every change has the required shape
    assert Enum.all?(changes, fn c ->
             Map.has_key?(c, :id) and Map.has_key?(c, :when) and
               Map.has_key?(c, :author_type) and Map.has_key?(c, :author_name) and
               Map.has_key?(c, :title)
           end)
  end

  test "diff returns before/after for a Change" do
    t = uniq("alice")
    scope = uniq("aurora")
    commit(t, scope, "* original\n", t)
    commit(t, scope, "* edited\n", t)

    {:ok, changes} = History.timeline(scope, t)
    newest = hd(changes)

    assert {:ok, %{before: before, after: aft}} = History.diff(scope, newest.id, t)
    assert before == "* original\n"
    assert aft == "* edited\n"
  end

  test "RESTORE IS APPEND-ONLY: a new Change is added and prior history is intact" do
    t = uniq("alice")
    scope = uniq("aurora")
    commit(t, scope, "* version one\n", t)
    commit(t, scope, "* version two\n", t)
    commit(t, scope, "* version three\n", t)

    {:ok, before} = History.timeline(scope, t)
    assert length(before) == 3
    oldest = List.last(before)

    # restore to the OLDEST version
    assert {:ok, change} = History.restore(scope, oldest.id, t)
    assert change.id != oldest.id

    {:ok, after_changes} = History.timeline(scope, t)
    # APPEND-ONLY: exactly one MORE change, nothing removed
    assert length(after_changes) == 4
    # every prior change id still present (nothing erased / rewritten)
    for c <- before, do: assert(Enum.any?(after_changes, &(&1.id == c.id)))

    # the working content now equals the restored (oldest) version
    assert {:ok, %{after: restored}} = History.diff(scope, hd(after_changes).id, t)
    assert restored == "* version one\n"
  end

  test "restore to a sha NOT in this scope's own timeline is rejected (:bad_id)" do
    t = uniq("alice")
    scope = uniq("aurora")
    other = uniq("nebula")
    commit(t, scope, "* aurora v1\n", t)
    commit(t, scope, "* aurora v2\n", t)
    # a SEPARATE workbook in the SAME tenant repo — its commits are real shas in the
    # repo but never touch <scope>.org, so they must NOT be a valid restore target.
    commit(t, other, "* nebula v1\n", t)
    commit(t, other, "* nebula v2\n", t)

    {:ok, other_changes} = History.timeline(other, t)
    foreign_id = hd(other_changes).id

    # the foreign sha is a real change, just not in `scope`'s timeline
    {:ok, scope_changes} = History.timeline(scope, t)
    refute Enum.any?(scope_changes, &(&1.id == foreign_id))

    assert History.restore(scope, foreign_id, t) == {:error, :bad_id}

    # scope's timeline is untouched (no spurious restore commit added)
    assert {:ok, after_changes} = History.timeline(scope, t)
    assert length(after_changes) == 2
  end

  test "a genuine restore COMMIT FAILURE surfaces as an error, not a false success" do
    t = uniq("alice")
    scope = uniq("aurora")
    commit(t, scope, "* v1\n", t)
    commit(t, scope, "* v2\n", t)

    {:ok, [newest, oldest]} = History.timeline(scope, t)

    # A REAL commit failure (not the clean-tree no-op): the working tree IS dirty
    # (restore writes the older content back) but git cannot write the commit object
    # because the object store is read-only. This must surface as {:error, _}, never
    # {:ok, :unchanged} — the bug the fix closed (a failed restore reported as a
    # no-op "success").
    dir = Git.repo_path(t)
    objects = Path.join([dir, ".git", "objects"])
    File.chmod!(objects, 0o500)

    result =
      try do
        History.restore(scope, oldest.id, t)
      after
        File.chmod!(objects, 0o755)
      end

    assert {:error, reason} = result
    assert is_binary(reason)

    # nothing falsely recorded: the timeline still has exactly the original 2 changes
    File.chmod!(objects, 0o755)
    assert {:ok, changes} = History.timeline(scope, t)
    assert length(changes) == 2
    assert hd(changes).id == newest.id
  end

  test "restoring identical content is :unchanged (no-op success), not a failure" do
    t = uniq("alice")
    scope = uniq("aurora")
    commit(t, scope, "* only\n", t)
    {:ok, [c]} = History.timeline(scope, t)

    # working copy already equals HEAD's content — restoring HEAD is a clean no-op.
    assert History.restore(scope, c.id, t) == {:ok, :unchanged}

    # APPEND-ONLY invariant intact: no spurious change added
    assert {:ok, changes} = History.timeline(scope, t)
    assert length(changes) == 1
  end

  test "human vs agent attribution" do
    t = uniq("alice")
    scope = uniq("aurora")
    # human deploy commits under the tenant's own name
    commit(t, scope, "* human edit\n", t)
    # agent write commits under an agent identity (the host git tool / ledger)
    commit(t, scope, "* agent edit\n", "agent-ledger")

    {:ok, changes} = History.timeline(scope, t)
    by_author = Map.new(changes, &{&1.author_name, &1.author_type})
    assert by_author[t] == :human
    assert by_author["agent-ledger"] == :agent
  end

  test "cross-tenant scope is invisible on timeline/diff/restore (-> :not_found)" do
    a = uniq("alice")
    b = uniq("bob")
    scope = uniq("bobsecret")
    commit(b, scope, "* bob private\n", b)
    commit(b, scope, "* bob private v2\n", b)

    {:ok, bchanges} = History.timeline(scope, b)
    id = hd(bchanges).id

    # tenant A cannot read or restore tenant B's history
    assert History.timeline(scope, a) == {:error, :not_found}
    assert History.diff(scope, id, a) == {:error, :not_found}
    assert History.restore(scope, id, a) == {:error, :not_found}

    # B's history is untouched by A's denied attempts
    assert {:ok, still} = History.timeline(scope, b)
    assert length(still) == 2
  end

  test "nil / empty caller tenant fails closed" do
    t = uniq("alice")
    scope = uniq("aurora")
    commit(t, scope, "* v1\n", t)
    {:ok, [c | _]} = History.timeline(scope, t)

    assert History.timeline(scope, nil) == {:error, :not_found}
    assert History.timeline(scope, "") == {:error, :not_found}
    assert History.diff(scope, c.id, nil) == {:error, :not_found}
    assert History.restore(scope, c.id, "") == {:error, :not_found}
  end

  test "scope with traversal / path chars is rejected (confinement, wb-g1yo.10)" do
    t = uniq("alice")
    # these are unknown ids -> :not_found (and the web layer rejects the chars too)
    assert History.timeline("../../../../etc/passwd", t) == {:error, :not_found}
    assert History.timeline("foo/bar", t) == {:error, :not_found}
    assert History.timeline("..", t) == {:error, :not_found}
  end

  test "unknown scope (never deployed) -> :not_found" do
    t = uniq("alice")
    assert History.timeline(uniq("ghost"), t) == {:error, :not_found}
  end
end
