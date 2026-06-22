defmodule Nexus.Autopoet.PlanTest do
  use ExUnit.Case, async: true
  alias Nexus.Autopoet.Plan
  alias Nexus.Autopoet.Plan.Handoff

  test "handoff requires title + task" do
    assert {:error, _} = Plan.handoff(%{title: "x"})
    assert {:ok, %Handoff{title: "T", task: "do it"}} = Plan.handoff(%{title: "T", task: "do it"})
  end

  test "render produces a self-contained brief with context, inputs, acceptance" do
    {:ok, h} = Plan.handoff(%{title: "Scrape feeds", task: "fetch + parse the 3 feeds", context: "RSS is XML", inputs: ["feed-a", "feed-b"], acceptance: "rows in /work/out.csv"})
    brief = Plan.render(h)
    assert brief =~ "# Scrape feeds"
    assert brief =~ "## Context\nRSS is XML"
    assert brief =~ "## Task\nfetch + parse"
    assert brief =~ "- feed-a"
    assert brief =~ "## Done when\nrows in /work/out.csv"
  end

  test "delineate builds an ordered plan of steps" do
    {:ok, a} = Plan.handoff(%{title: "A", task: "step a"})
    {:ok, b} = Plan.handoff(%{title: "B", task: "step b"})
    plan = Plan.delineate("ship the lander", [a, b])
    assert plan.goal == "ship the lander"
    assert length(plan.steps) == 2
  end

  test "dispatch runs each handoff through a pluggable runner" do
    {:ok, a} = Plan.handoff(%{title: "A", task: "step a"})
    {:ok, b} = Plan.handoff(%{title: "B", task: "step b"})
    plan = Plan.delineate("goal", [a, b])
    results = Plan.dispatch(plan, fn h -> {:ok, "ran " <> h.title} end)
    assert [%{title: "A", result: {:ok, "ran A"}}, %{title: "B", result: {:ok, "ran B"}}] = results
  end

  test "a step with no assignee yields :no_assignee under the default runner" do
    {:ok, a} = Plan.handoff(%{title: "A", task: "step a"})
    assert [%{result: {:error, :no_assignee}}] = Plan.dispatch(Plan.delineate("g", [a]))
  end

  test "file emits a plan.created parent and a task.created per step" do
    {:ok, a} = Plan.handoff(%{title: "A", task: "step a", assignee: "w"})
    parent = Plan.file(Plan.delineate("goal", [a]))
    assert parent.kind == "plan.created"
    assert Map.has_key?(parent, :id)
  end
end
