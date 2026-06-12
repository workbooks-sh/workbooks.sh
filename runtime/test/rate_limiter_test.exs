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
end
