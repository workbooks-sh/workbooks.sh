defmodule Workbooks.Keeper.LifecycleTest do
  use ExUnit.Case, async: false

  @moduledoc """
  The declared lifecycle state machine (wb-2ku.3). Hermetic — no LLM, no keeper
  GenServer: drives `Workbooks.Keeper.Lifecycle` directly with a tmp WB_DATA and a
  tmp spec file. Covers: parse; the 3-add→audit→rem→loop progression; failure
  retry preserving position; and the persistence round-trip.
  """

  alias Workbooks.Keeper.Lifecycle

  @spec_org """
  #+START: wake_add
  * wake_add
  :PROPERTIES:
  :KIND: wake
  :REPEAT: 3
  :NEXT: wake_audit
  :END:
  Add work.

  * wake_audit
  :PROPERTIES:
  :KIND: wake
  :NEXT: rem
  :END:
  Audit.

  * rem
  :PROPERTIES:
  :KIND: rem
  :NEXT: wake_add
  :MIN-INTERVAL: 45m
  :END:
  Dream.
  """

  setup do
    tmp = Path.join(System.tmp_dir!(), "wb_lifecycle_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    spec = Path.join(tmp, "lifecycle.org")
    File.write!(spec, @spec_org)

    prev_data = System.get_env("WB_DATA")
    prev_def = System.get_env("WB_LIFECYCLE_DEF")
    System.put_env("WB_DATA", tmp)
    System.put_env("WB_LIFECYCLE_DEF", spec)

    on_exit(fn ->
      File.rm_rf(tmp)
      if prev_data, do: System.put_env("WB_DATA", prev_data), else: System.delete_env("WB_DATA")
      if prev_def, do: System.put_env("WB_LIFECYCLE_DEF", prev_def), else: System.delete_env("WB_LIFECYCLE_DEF")
    end)

    %{spec: spec, tmp: tmp}
  end

  describe "parse/1" do
    test "reads states, kinds, repeat, next, and the time gate" do
      states = Lifecycle.parse(@spec_org)
      assert map_size(states) == 3

      assert states["wake_add"].kind == :wake
      assert states["wake_add"].repeat == 3
      assert states["wake_add"].next == "wake_audit"

      assert states["wake_audit"].kind == :wake
      # defaulted repeat
      assert states["wake_audit"].repeat == 1

      assert states["rem"].kind == :rem
      # 45m → ms
      assert states["rem"].min_interval_ms == 45 * 60_000
    end

    test "start_state honors #+START:, else first heading" do
      states = Lifecycle.parse(@spec_org)
      assert Lifecycle.start_state(@spec_org, states) == "wake_add"
      assert Lifecycle.start_state("* z\n* a\n", Lifecycle.parse("* z\n* a\n")) == "a"
    end

    test "empty / heading-less org → nil (keeper falls back)" do
      assert Lifecycle.parse("just prose, no headings") == nil
      assert Lifecycle.parse("") == nil
    end
  end

  describe "progression: wake_add ×3 → wake_audit → rem → loop" do
    test "three successful adds accrue, then audit, then rem, then back to add" do
      assert Lifecycle.current().state == "wake_add"
      assert Lifecycle.current().hits == 0

      # add #1, #2 stay in wake_add
      assert Lifecycle.advance(:done).state == "wake_add"
      assert Lifecycle.current().hits == 1
      assert Lifecycle.advance(:done).state == "wake_add"
      assert Lifecycle.current().hits == 2

      # add #3 satisfies REPEAT 3 → wake_audit
      assert Lifecycle.advance(:done).state == "wake_audit"
      assert Lifecycle.current().hits == 0

      # audit (repeat 1) → rem
      assert Lifecycle.advance(:done).state == "rem"

      # rem → loops back to wake_add
      assert Lifecycle.advance(:done).state == "wake_add"
      assert Lifecycle.current().hits == 0
    end
  end

  describe "failure edge" do
    test "a failed/killed run keeps the same state and cadence position" do
      assert Lifecycle.advance(:done).state == "wake_add"
      assert Lifecycle.current().hits == 1

      # failure does not advance and does not lose the hit count
      assert Lifecycle.advance(:failed).state == "wake_add"
      assert Lifecycle.current().hits == 1
      assert Lifecycle.advance(:killed).state == "wake_add"
      assert Lifecycle.current().hits == 1

      # resuming success continues from where we were (2nd then 3rd add → audit)
      assert Lifecycle.advance(:done).state == "wake_add"
      assert Lifecycle.current().hits == 2
      assert Lifecycle.advance(:done).state == "wake_audit"
    end
  end

  describe "gates" do
    test "rem is gated until its min-interval elapses since it last ran" do
      # walk to rem
      Lifecycle.advance(:done)
      Lifecycle.advance(:done)
      Lifecycle.advance(:done)
      Lifecycle.advance(:done)
      assert Lifecycle.current().state == "rem"
      # never ran → gate open
      refute Lifecycle.current().gated

      # record a recent run → 45m gate now closed
      Lifecycle.mark_ran("rem")
      assert Lifecycle.current().gated
    end
  end

  describe "persistence round-trip" do
    test "position survives a 'restart' (fresh read from disk)" do
      Lifecycle.advance(:done)
      Lifecycle.advance(:done)
      assert Lifecycle.current().state == "wake_add"
      assert Lifecycle.current().hits == 2

      # simulate restart by clearing the persistent_term mirror; the next read
      # must recover {state, hits} from the data volume.
      :persistent_term.erase({Workbooks.Keeper.Lifecycle, :state})

      assert Lifecycle.current().state == "wake_add"
      assert Lifecycle.current().hits == 2
    end
  end

  describe "inactive (no spec)" do
    test "current/advance/status are nil when WB_LIFECYCLE_DEF is unset" do
      System.delete_env("WB_LIFECYCLE_DEF")
      refute Lifecycle.active?()
      assert Lifecycle.current() == nil
      assert Lifecycle.advance(:done) == nil
      assert Lifecycle.status() == nil
    end
  end
end
