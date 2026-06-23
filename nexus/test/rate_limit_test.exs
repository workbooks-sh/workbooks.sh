defmodule Nexus.RateLimitTest do
  use ExUnit.Case, async: false

  alias Nexus.RateLimit

  # wb-9g6s — per-tenant fixed-window cap behind the Dock complete/fetch caps.

  setup do
    RateLimit.init()
    :ok
  end

  test "permits up to `limit` per window, then blocks — per tenant" do
    t = "tenant-#{System.unique_integer([:positive])}"
    # big window so it can't roll over mid-test
    assert RateLimit.allow?(t, :llm, 3, 3600)
    assert RateLimit.allow?(t, :llm, 3, 3600)
    assert RateLimit.allow?(t, :llm, 3, 3600)
    refute RateLimit.allow?(t, :llm, 3, 3600)
    refute RateLimit.allow?(t, :llm, 3, 3600)
  end

  test "tenants and kinds are independent buckets" do
    a = "a-#{System.unique_integer([:positive])}"
    b = "b-#{System.unique_integer([:positive])}"
    assert RateLimit.allow?(a, :llm, 1, 3600)
    refute RateLimit.allow?(a, :llm, 1, 3600)
    # different tenant — fresh budget
    assert RateLimit.allow?(b, :llm, 1, 3600)
    # different kind, same tenant — fresh budget
    assert RateLimit.allow?(a, :fetch, 1, 3600)
  end

  test "limit 0 (or negative) means uncapped" do
    t = "u-#{System.unique_integer([:positive])}"
    for _ <- 1..50, do: assert(RateLimit.allow?(t, :llm, 0, 3600))
  end

  test "a new window resets the budget" do
    t = "w-#{System.unique_integer([:positive])}"
    # window_secs=1 → consume the budget, then the next whole second is a fresh window.
    assert RateLimit.allow?(t, :llm, 1, 1)
    refute RateLimit.allow?(t, :llm, 1, 1)
    Process.sleep(1100)
    assert RateLimit.allow?(t, :llm, 1, 1)
  end
end
