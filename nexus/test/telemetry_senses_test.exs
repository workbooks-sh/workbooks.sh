defmodule Nexus.TelemetrySensesTest do
  use ExUnit.Case, async: false
  alias Nexus.Telemetry

  defp run(status), do: %{at: 0, turns: 2, tokens: %{total: 100}, latency_ms: 50, tools: %{"bash" => 1}, status: status}

  setup do
    Telemetry.reset()
    on_exit(&Telemetry.reset/0)
    :ok
  end

  test "ledger aggregates every unit's runs" do
    for _ <- 1..3, do: Telemetry.record("healthy", run(:ok))
    led = Telemetry.ledger()
    key = Nexus.Uid.key("healthy")
    assert led[key].runs == 3
    assert led[key].errors == 0
  end

  test "concerns flags a unit that fails too often" do
    for _ <- 1..4, do: Telemetry.record("flaky", run(:error))
    Telemetry.record("flaky", run(:ok))
    concerns = Telemetry.concerns()
    key = Nexus.Uid.key("flaky")
    assert Enum.any?(concerns, fn {k, _s, reasons} ->
             k == key and Enum.any?(reasons, &match?({:error_rate, _}, &1))
           end)
  end

  test "a unit that never succeeded is flagged :no_success" do
    for _ <- 1..3, do: Telemetry.record("doomed", run(:error))
    concerns = Telemetry.concerns()
    key = Nexus.Uid.key("doomed")
    assert Enum.any?(concerns, fn {k, _s, reasons} -> k == key and :no_success in reasons end)
  end

  test "a healthy unit raises no concern" do
    for _ <- 1..5, do: Telemetry.record("solid", run(:ok))
    refute Enum.any?(Telemetry.concerns(), fn {k, _s, _r} -> k == Nexus.Uid.key("solid") end)
  end

  test "units below min_runs are not judged (too little signal)" do
    Telemetry.record("new", run(:error))
    refute Enum.any?(Telemetry.concerns(), fn {k, _s, _r} -> k == Nexus.Uid.key("new") end)
  end
end
