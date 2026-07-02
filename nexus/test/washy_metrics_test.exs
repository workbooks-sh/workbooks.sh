defmodule TinyLasers.WasmMetricsTest do
  @moduledoc """
  Phase E (wb-zbc3): Washy operability — the metrics core (lock-free counters + reason histograms) and
  the load gate: many concurrent shell runs complete correctly while the metrics reflect throughput,
  concurrency (peak in-flight), latency, and the density gauge.
  """
  use ExUnit.Case, async: false
  # the shell meters via the tiny-lasers substrate now (vendor-back, wb-5te7)
  alias TinyLasers.Wasm.Metrics

  setup do
    Metrics.ensure()
    Metrics.reset()
    :ok
  end

  test "metrics bracket a run: outcome counts, latency, fuel, traps-by-reason" do
    m = Metrics.start_run(65_536)
    s = Metrics.snapshot()
    assert s.in_flight == 1
    assert s.peak_in_flight >= 1
    assert s.cells_per_gb != nil and s.cells_per_gb > 0

    Metrics.finish_run(m, :ok, fuel_used: 12_345, out_bytes: 7)
    s2 = Metrics.snapshot()
    assert s2.total == 1
    assert s2.ok == 1
    assert s2.in_flight == 0
    assert s2.fuel_used == 12_345
    assert s2.out_bytes == 7
    assert s2.avg_latency_us >= 0
    assert Map.has_key?(s2.fuel_log2, trunc(:math.log2(12_345)))

    # a trap records its reason
    m2 = Metrics.start_run(0)
    Metrics.finish_run(m2, :trap, reason: :out_of_fuel)
    assert Metrics.snapshot().traps_by_reason[:out_of_fuel] == 1
  end

  test "the in-flight gauge never leaks across outcomes" do
    for outcome <- [:ok, :timeout, :error] do
      m = Metrics.start_run(1000)
      Metrics.finish_run(m, outcome)
    end

    assert Metrics.snapshot().in_flight == 0
    assert Metrics.snapshot().total == 3
  end

  @tag timeout: 120_000
  test "BACKPRESSURE: a low concurrency cap bounds peak in-flight; all runs still complete" do
    if Nexus.Shell.available?() do
      dir = Path.join(System.tmp_dir!(), "wb-bp-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      Nexus.Shell.run("echo warm", dir)
      Metrics.reset()

      n = 40

      results =
        1..n
        |> Task.async_stream(
          fn i -> Nexus.Shell.run("echo b#{i} | upper", dir, max_concurrent: 3) |> elem(0) end,
          max_concurrency: n,
          timeout: 60_000
        )
        |> Enum.map(fn {:ok, out} -> out end)

      # correctness preserved under backpressure
      assert Enum.all?(1..n, fn i -> "B#{i}\n" in results end)
      s = Metrics.snapshot()
      assert s.total == n and s.ok == n and s.in_flight == 0
      # soft cap (3) bounds peak — allow slack for the start_run race, but well under the 40 offered
      assert s.peak_in_flight <= 12, "peak #{s.peak_in_flight} should stay near the cap of 3"
    else
      IO.puts("\n[skip] C wasm lane not built")
    end
  end

  @tag timeout: 120_000
  test "LOAD: many concurrent shell runs complete + metrics reflect throughput/concurrency/density" do
    if Nexus.Shell.available?() do
      Metrics.reset()
      dir = Path.join(System.tmp_dir!(), "wb-load-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      # warm the shared caches (shell wasm decode + coreutils registry) before the concurrent burst,
      # so 100 runs don't each race to decode the 9.6MB registry
      Nexus.Shell.run("echo warm", dir)
      Metrics.reset()
      n = 100

      results =
        1..n
        |> Task.async_stream(
          fn i -> Nexus.Shell.run("echo n#{i} | upper", dir) |> elem(0) end,
          max_concurrency: n,
          timeout: 60_000
        )
        |> Enum.map(fn {:ok, out} -> out end)

      # every run produced the right answer (echo n<i> | upper)
      assert Enum.all?(1..n, fn i -> "N#{i}\n" in results end)

      s = Metrics.snapshot()
      assert s.total == n
      assert s.ok == n
      assert s.in_flight == 0
      assert s.peak_in_flight > 1, "runs should have overlapped (peak=#{s.peak_in_flight})"
      assert s.avg_latency_us > 0
    else
      IO.puts("\n[skip] C wasm lane not built")
    end
  end
end
