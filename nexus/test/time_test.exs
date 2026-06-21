defmodule Nexus.TimeTest do
  use ExUnit.Case, async: true
  alias Nexus.Time, as: T

  describe "duration_ms/1" do
    test "single + stacked units" do
      assert T.duration_ms("90s") == {:ok, 90_000}
      assert T.duration_ms("15m") == {:ok, 900_000}
      assert T.duration_ms("2h") == {:ok, 7_200_000}
      assert T.duration_ms("1d") == {:ok, 86_400_000}
      assert T.duration_ms("1w") == {:ok, 604_800_000}
      assert T.duration_ms("1d30m") == {:ok, 86_400_000 + 1_800_000}
    end

    test "bare integer = seconds, passthrough ms, junk = :error" do
      assert T.duration_ms("30") == {:ok, 30_000}
      assert T.duration_ms(5_000) == {:ok, 5_000}
      assert T.duration_ms("nope") == :error
    end
  end

  describe "spec/1 from keywords" do
    test "every / after / at / cron" do
      assert {:ok, %{kind: :every, ms: 900_000}} = T.spec(every: "15m")
      assert {:ok, %{kind: :after, ms: 300_000}} = T.spec(after: "5m")
      assert {:ok, %{kind: :at, hour: 14, minute: 0}} = T.spec(at: "14:00")
      assert {:ok, %{kind: :cron}} = T.spec(cron: "0 2 * * *")
    end

    test "bad inputs" do
      assert {:error, _} = T.spec(every: "huh")
      assert {:error, :no_time_field} = T.spec(foo: 1)
    end
  end

  describe "cron parse + next_fire" do
    test "daily 02:00 fires at the next 02:00" do
      {:ok, spec} = T.parse_cron("0 2 * * *")
      from = ~U[2026-06-20 10:00:00Z]
      assert {:ok, ~U[2026-06-21 02:00:00Z]} = T.next_fire(spec, from)
    end

    test "step + range fields" do
      {:ok, spec} = T.parse_cron("*/15 9-17 * * 1-5")
      # Monday 2026-06-22 08:50 → next quarter-hour within 9-17 on a weekday
      from = ~U[2026-06-22 08:50:00Z]
      assert {:ok, ~U[2026-06-22 09:00:00Z]} = T.next_fire(spec, from)
    end

    test "weekday-only skips the weekend" do
      {:ok, spec} = T.parse_cron("0 9 * * 1")
      # Sat 2026-06-20 → next Monday 09:00 is 2026-06-22
      from = ~U[2026-06-20 12:00:00Z]
      assert {:ok, ~U[2026-06-22 09:00:00Z]} = T.next_fire(spec, from)
    end

    test "rejects malformed cron" do
      assert {:error, _} = T.parse_cron("0 2 * *")
      assert {:error, _} = T.parse_cron("99 2 * * *")
    end
  end

  describe "relative + clock next_fire" do
    test "every/after add the interval" do
      from = ~U[2026-06-20 10:00:00Z]
      assert {:ok, dt1} = T.next_fire(%{kind: :every, ms: 900_000}, from)
      assert DateTime.truncate(dt1, :second) == ~U[2026-06-20 10:15:00Z]
      assert {:ok, dt2} = T.next_fire(%{kind: :after, ms: 300_000}, from)
      assert DateTime.truncate(dt2, :second) == ~U[2026-06-20 10:05:00Z]
    end

    test "at rolls to tomorrow when the time already passed today" do
      {:ok, spec} = T.spec(at: "08:00")
      from = ~U[2026-06-20 10:00:00Z]
      assert {:ok, ~U[2026-06-21 08:00:00Z]} = T.next_fire(spec, from)
    end
  end

  describe "org timestamps" do
    test "plain future timestamp" do
      assert {:ok, %{kind: :timestamp, at: ~U[2026-06-21 14:00:00Z], repeat: nil, duration_s: nil}} =
               T.parse_timestamp("<2026-06-21 Sun 14:00>")
    end

    test "span yields a duration" do
      assert {:ok, %{duration_s: 5400}} = T.parse_timestamp("<2026-06-21 14:00-15:30>")
    end

    test "repeater advances past now" do
      {:ok, spec} = T.parse_timestamp("<2026-06-21 09:00 +1w>")
      from = ~U[2026-07-01 00:00:00Z]
      # +1w from 06-21: 06-28, 07-05 → first after 07-01 is 07-05
      assert {:ok, ~U[2026-07-05 09:00:00Z]} = T.next_fire(spec, from)
    end

    test "past one-shot timestamp = :none" do
      {:ok, spec} = T.parse_timestamp("<2020-01-01 09:00>")
      assert :none = T.next_fire(spec, ~U[2026-06-20 00:00:00Z])
    end

    test "monthly repeater handles month rollover" do
      {:ok, spec} = T.parse_timestamp("<2026-01-31 09:00 +1m>")
      from = ~U[2026-02-15 00:00:00Z]
      # Jan 31 +1m clamps to Feb 28
      assert {:ok, ~U[2026-02-28 09:00:00Z]} = T.next_fire(spec, from)
    end
  end

  describe "ms_until + repeating?" do
    test "ms_until never negative" do
      assert T.ms_until(%{kind: :after, ms: 1000}, ~U[2026-06-20 10:00:00Z]) == 1000
    end

    test "repeating? classification" do
      assert T.repeating?(%{kind: :every, ms: 1})
      assert T.repeating?(%{kind: :cron})
      refute T.repeating?(%{kind: :after, ms: 1})
      refute T.repeating?(%{kind: :timestamp, repeat: nil})
      assert T.repeating?(%{kind: :timestamp, repeat: {:plus, 1, :week}})
    end
  end
end
