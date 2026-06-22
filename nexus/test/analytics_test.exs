defmodule Nexus.AnalyticsTest do
  use ExUnit.Case, async: false
  alias Nexus.Analytics

  setup do
    Analytics.reset()
    on_exit(&Analytics.reset/0)
    :ok
  end

  defp sync, do: Analytics.counts("t1")  # a call flushes prior casts

  test "track increments per-tenant counts" do
    Analytics.track("page_view", "t1")
    Analytics.track("page_view", "t1")
    Analytics.track("signup", "t1")
    sync()
    assert Analytics.count("page_view", "t1") == 2
    assert Analytics.count("signup", "t1") == 1
  end

  test "tenants are isolated" do
    Analytics.track("page_view", "t1")
    Analytics.track("page_view", "t2")
    Analytics.track("page_view", "t2")
    sync()
    assert Analytics.count("page_view", "t1") == 1
    assert Analytics.count("page_view", "t2") == 2
  end

  test "funnel reports conversion rates relative to the first step" do
    for _ <- 1..10, do: Analytics.track("view", "t1")
    for _ <- 1..4, do: Analytics.track("click", "t1")
    for _ <- 1..1, do: Analytics.track("buy", "t1")
    sync()
    [view, click, buy] = Analytics.funnel(["view", "click", "buy"], "t1")
    assert view.count == 10 and view.rate == 1.0
    assert click.count == 4 and click.rate == 0.4
    assert buy.count == 1 and buy.rate == 0.1
  end

  test "recent returns newest-first, capped" do
    Analytics.track("a", "t1")
    Analytics.track("b", "t1")
    assert [%{name: "b"}, %{name: "a"}] = Analytics.recent("t1", 50)
  end

  test "summary totals usage" do
    Analytics.track("a", "t1")
    Analytics.track("a", "t1")
    Analytics.track("b", "t1")
    sync()
    s = Analytics.summary("t1")
    assert s.total == 3 and s.distinct == 2
  end
end
