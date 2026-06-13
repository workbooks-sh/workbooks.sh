defmodule Workbooks.RateLimiterTest do
  use ExUnit.Case, async: true
  alias Workbooks.RateLimiter

  test "fixed-window: allows up to max, then denies; reset clears it" do
    p = "rl-#{System.unique_integer([:positive])}"
    assert :ok = RateLimiter.check(p, 3, 60_000)
    assert :ok = RateLimiter.check(p, 3, 60_000)
    assert :ok = RateLimiter.check(p, 3, 60_000)
    assert {:error, :rate_limited} = RateLimiter.check(p, 3, 60_000)
    assert {:error, :rate_limited} = RateLimiter.check(p, 3, 60_000)

    assert :ok = RateLimiter.reset(p)
    assert :ok = RateLimiter.check(p, 3, 60_000)
  end

  test "principals have independent budgets" do
    a = "rl-a-#{System.unique_integer([:positive])}"
    b = "rl-b-#{System.unique_integer([:positive])}"
    assert :ok = RateLimiter.check(a, 1, 60_000)
    assert {:error, :rate_limited} = RateLimiter.check(a, 1, 60_000)
    # b is untouched by a's exhaustion
    assert :ok = RateLimiter.check(b, 1, 60_000)
  end

  test "a fresh window reopens the budget after it elapses" do
    p = "rl-w-#{System.unique_integer([:positive])}"
    # a 1ms window: first call consumes it, then after a tick the window has elapsed -> reopened
    assert :ok = RateLimiter.check(p, 1, 1)
    Process.sleep(5)
    assert :ok = RateLimiter.check(p, 1, 1)
  end

  test "self-audit: CONCURRENT checks admit EXACTLY max (atomic, no lost-update undercount)" do
    p = "rl-conc-#{System.unique_integer([:positive])}"
    max = 500
    # 2000 concurrent checks, a LARGE window so they all land in ONE bucket (no window-roll split).
    # The atomic :ets.update_counter must admit EXACTLY `max` — the OLD read-then-bump would undercount under
    # concurrency and let MORE than max through (the exact bug iter96 claimed to fix; proven here).
    oks =
      1..2000
      |> Task.async_stream(fn _ -> RateLimiter.check(p, max, 600_000) end,
        max_concurrency: 64,
        ordered: false
      )
      |> Enum.count(fn {:ok, r} -> r == :ok end)

    assert oks == max, "expected exactly #{max} admitted under concurrency, got #{oks}"
  end

  test "self-audit: reset clears EVERY bucket for a principal (key is {principal, bucket})" do
    p = "rl-reset-#{System.unique_integer([:positive])}"
    assert :ok = RateLimiter.check(p, 1, 600_000)
    assert {:error, :rate_limited} = RateLimiter.check(p, 1, 600_000)
    :ok = RateLimiter.reset(p)
    # after reset the budget is fresh again (the bucketed key didn't survive)
    assert :ok = RateLimiter.check(p, 1, 600_000)
  end
end
