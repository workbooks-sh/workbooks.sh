defmodule Nexus.TelemetryTest do
  use ExUnit.Case
  alias WorkCore.Graph

  setup do
    Nexus.Telemetry.reset()
    on_exit(&Nexus.Telemetry.reset/0)
    :ok
  end

  defp run(attrs) do
    Map.merge(
      %{at: 0, turns: 1, tokens: %{prompt: 10, completion: 5, total: 15}, latency_ms: 100, tools: %{}, status: :ok, error: nil},
      attrs
    )
  end

  test "records runs and aggregates an observed facet" do
    Nexus.Telemetry.record("enrich", run(%{turns: 2, tokens: %{prompt: 0, completion: 0, total: 30}, tools: %{"jq" => 1}}))
    Nexus.Telemetry.record("enrich", run(%{turns: 3, tokens: %{prompt: 0, completion: 0, total: 20}, tools: %{"jq" => 1, "curl" => 2}, status: :error}))

    s = Nexus.Telemetry.summary("enrich")
    assert s.runs == 2
    assert s.turns == 5
    assert s.tokens == 50
    assert "jq" in s.tools_used and "curl" in s.tools_used
    assert s.errors == 1
    # nil for a unit that never ran
    assert Nexus.Telemetry.summary("ghost") == nil
  end

  test "overlay projects the ledger onto the graph; observed vs declared caps is computable" do
    tmp = Path.join(System.tmp_dir!(), "nx_tel_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    File.write!(Path.join(tmp, "worker.work"), "# Worker\n\n```elixir\nserver :worker, grant: [net: \"x\"] do\n  def go, do: :ok\nend\n```\n")
    on_exit(fn -> File.rm_rf!(tmp) end)

    g = Graph.build_dir(tmp)

    Nexus.Telemetry.record("worker", run(%{tools: %{"curl" => 3, "fs-write" => 1}}))
    ov = Nexus.Telemetry.overlay()
    lensed = Graph.with_overlay(g, ov)

    observed = lensed.nodes["worker"].facets.observed
    assert observed.runs == 1
    assert "curl" in observed.tools_used

    # the pure graph is untouched by the lens
    assert g.nodes["worker"].facets.observed == nil

    # declared (host_cap grants) vs observed (tools the agent actually invoked) —
    # the audit join the overlay exists to enable
    declared = Graph.host_caps(g, "worker")
    assert "net" in declared
    assert is_list(observed.tools_used)
  end

  test "overlay keys by canonical Uid (name surface-form independent)" do
    Nexus.Telemetry.record(:worker, run(%{}))
    assert Nexus.Telemetry.summary("worker").runs == 1
  end
end
