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
