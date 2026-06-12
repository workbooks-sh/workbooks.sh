defmodule Workbooks.BrokerNetE2ETest do
  @moduledoc """
  wb-0beq regression: a REAL wasi:http component guest does OUTBOUND fetches through the patched runtime.
  Before the spawn_blocking fix, an outbound fetch PANICKED ("Cannot start a runtime from within a runtime").
  Now the call returns gracefully — internal targets are SSRF-blocked, a public target is reachable.
  """
  use ExUnit.Case, async: false

  @tag :build
  @tag timeout: 300_000
  test "wasi-http OUTBOUND works through the broker — internal SSRF-blocked, public reachable, no panic" do
    out = Path.join(System.tmp_dir!(), "net_probe_#{System.unique_integer([:positive])}.component.wasm")

    {_, 0} =
      System.cmd(
        "node",
        [
          "node_modules/.bin/jco",
          "componentize",
          "test/broker_e2e/net_probe.js",
          "--wit",
          "test/broker_e2e/net_probe.wit",
          "-n",
          "net-probe",
          "--enable",
          "http",
          "--enable",
          "random",
          "--enable",
          "clocks",
          "-o",
          out
        ],
        stderr_to_stdout: true
      )

    {:ok, pid} =
      Wasmex.Components.start_link(%{path: out, wasi: %Wasmex.Wasi.WasiP2Options{allow_http: true}})

    on_exit(fn -> File.rm(out) end)
    probe = fn url -> Wasmex.Components.call_function(pid, "probe", [url], 12_000) end

    # SSRF floor on the now-WORKING outbound path: internal targets are blocked by the host override
    assert {:ok, meta} = probe.("http://169.254.169.254/")
    assert meta =~ "BLOCKED"
    assert {:ok, loop} = probe.("http://127.0.0.1/")
    assert loop =~ "BLOCKED"

    # The fix itself: a PUBLIC fetch now returns GRACEFULLY ({:ok, _}) instead of panicking the worker.
    # With connectivity this is "OK <status>" (reachability); offline it's a graceful connection error —
    # either way the component call no longer traps.
    assert {:ok, _pub} = probe.("http://1.1.1.1/")
  end

  @tag :build
  @tag :netdeps
  test "RECLAMATION — a standard wasi:http fetch tool retrieves real web content through the broker (SSRF-safe)" do
    out = Path.join(System.tmp_dir!(), "fetch_#{System.unique_integer([:positive])}.component.wasm")

    {_, 0} =
      System.cmd(
        "node",
        ["node_modules/.bin/jco", "componentize", "test/broker_e2e/fetch.js", "--wit",
         "test/broker_e2e/net_probe.wit", "-n", "net-probe", "--enable", "http", "--enable",
         "random", "--enable", "clocks", "-o", out],
        stderr_to_stdout: true
      )

    {:ok, pid} =
      Wasmex.Components.start_link(%{path: out, wasi: %Wasmex.Wasi.WasiP2Options{allow_http: true}})

    on_exit(fn -> File.rm(out) end)
    probe = fn url -> Wasmex.Components.call_function(pid, "probe", [url], 15_000) end

    # internal is still SSRF-blocked on the working path
    assert {:ok, m} = probe.("http://169.254.169.254/")
    assert m =~ "BLOCKED"
    # public: REAL web content retrieved through the brokered, SSRF-filtered outbound path
    assert {:ok, body} = probe.("http://example.com/")
    assert body =~ "Example Domain"
  end

  @tag :build
  @tag :netdeps
  test "LIVE — a reclaimed wasi:http fetch tool runs via the PRODUCTION Instance lane (:network), SSRF-safe" do
    out = Path.join(System.tmp_dir!(), "fetch_inst_#{System.unique_integer([:positive])}.component.wasm")

    {_, 0} =
      System.cmd(
        "node",
        ["node_modules/.bin/jco", "componentize", "test/broker_e2e/fetch.js", "--wit",
         "test/broker_e2e/net_probe.wit", "-n", "net-probe", "--enable", "http", "--enable",
         "random", "--enable", "clocks", "-o", out],
        stderr_to_stdout: true
      )

    bytes = File.read!(out)
    on_exit(fn -> File.rm(out) end)
    id = "fetch-#{System.unique_integer([:positive])}"

    # the SAME path the runtime uses for real component tools: Instance + the :network profile (allow_http)
    {:ok, _} = Workbooks.Instance.Supervisor.start_instance(id, bytes, policy: :network)
    on_exit(fn -> Workbooks.Instance.Supervisor.stop_instance(id) end)

    # real web content retrieved via the production lane
    assert {:ok, body} = Workbooks.Instance.call(id, "probe", ["http://example.com/"])
    assert body =~ "Example Domain"
    # SSRF floor enforced on the production lane
    assert {:ok, blocked} = Workbooks.Instance.call(id, "probe", ["http://169.254.169.254/"])
    assert blocked =~ "BLOCKED"
  end
end
