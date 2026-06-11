defmodule Workbooks.KeeperBackoffTest do
  use ExUnit.Case, async: true

  # Idle backoff (efficiency): an idle continuous crew was re-running every
  # breather (~10s), each tick an LLM call returning NO-WORK. The NO-WORK streak
  # must back the next tick off to minutes, and a single :done (streak 0) must
  # snap back to the hot base cadence so the newsroom stays responsive.

  alias Workbooks.Keeper.Worker.Cfg
  alias Workbooks.Keeper.Worker

  @cont %Cfg{continuous: true, breather_ms: 10_000}
  @interval %Cfg{continuous: false, interval_ms: 3_600_000}

  test "streak 0 keeps the hot base cadence (no penalty when there is work)" do
    assert Worker.tick_delay_for_test(@cont, 0) == 10_000
    assert Worker.tick_delay_for_test(@interval, 0) == 3_600_000
  end

  test "a NO-WORK streak backs a continuous worker off, escalating and capped" do
    d1 = Worker.tick_delay_for_test(@cont, 1)
    d2 = Worker.tick_delay_for_test(@cont, 2)
    d3 = Worker.tick_delay_for_test(@cont, 3)

    # 1min, 2min, 4min … strictly increasing, far above the 10s breather
    assert d1 == 60_000
    assert d2 == 120_000
    assert d3 == 240_000
    assert d1 > @cont.breather_ms

    # capped at 30min no matter how long the idle streak runs
    assert Worker.tick_delay_for_test(@cont, 50) == 1_800_000
  end

  test "backoff never shortens a base cadence already longer than the backoff" do
    # an hourly interval worker with a 1-streak: backoff (1min) must not speed it
    # up — max(base, backoff) keeps the hourly cadence.
    assert Worker.tick_delay_for_test(@interval, 1) == 3_600_000
  end
end
