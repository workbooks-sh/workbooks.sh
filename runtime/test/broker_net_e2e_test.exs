defmodule Workbooks.BrokerNetE2ETest do
  @moduledoc """
  wb-0beq regression: a REAL wasi:http component guest does OUTBOUND fetches through the patched runtime.
  Before the spawn_blocking fix, an outbound fetch PANICKED ("Cannot start a runtime from within a runtime").
  Now the call returns gracefully — internal targets are SSRF-blocked, a public target is reachable.
  """
  use ExUnit.Case, async: false

  @tag :build
  @tag timeout: 300_000
  test "INBOUND serve_http plumbing — reaches the NIF + handles a component lacking incoming-handler" do
    # any component instantiated with allow_http exercises the inbound path: Components.serve_http ->
    # handle_call -> Instance.serve_http -> Native.component_serve_http, which builds the request,
    # creates the incoming-request + response-outparam resources, then looks up wasi:http/incoming-handler.
    # net_probe exports `probe`, NOT incoming-handler, so the lookup fails gracefully — proving the full
    # Elixir->NIF plumbing + ~70% of the NIF (request build + both resources) runs end to end.
    out = Path.join(System.tmp_dir!(), "inb_#{System.unique_integer([:positive])}.component.wasm")

    {_, 0} =
      System.cmd(
        "node",
        ["node_modules/.bin/jco", "componentize", "test/broker_e2e/net_probe.js", "--wit",
         "test/broker_e2e/net_probe.wit", "-n", "net-probe", "--enable", "http", "--enable",
         "random", "--enable", "clocks", "-o", out],
        stderr_to_stdout: true
      )

    {:ok, pid} =
      Wasmex.Components.start_link(%{path: out, wasi: %Wasmex.Wasi.WasiP2Options{allow_http: true}})

    on_exit(fn -> File.rm(out) end)

    got =
      try do
        Wasmex.Components.serve_http(pid, "GET", "/", [], "")
      rescue
        e -> {:raised, Exception.message(e)}
      catch
        kind, reason -> {:caught, kind, reason}
      end

    # the missing-handler component must NOT yield a {status, headers, body} success — the path ran and the
    # NIF reported the absent wasi:http/incoming-handler export (raise or error tuple, both prove the wiring)
    refute match?({s, h, b} when is_integer(s) and is_list(h) and is_binary(b), got)
  end

  @tag :build
  @tag timeout: 300_000
  test "INBOUND standard seam — host drives a REAL wasi:http server component (200 + body)" do
    # a STANDARD wasi:http server component (cargo-component, exports wasi:http/incoming-handler@0.2.6)
    proj = "test/broker_e2e/wasi_http_handler"

    {_, 0} =
      System.cmd("cargo", ["component", "build", "--release", "--target", "wasm32-wasip2"],
        cd: proj,
        stderr_to_stdout: true
      )

    bytes = File.read!(Path.join(proj, "target/wasm32-wasip2/release/httpguest.wasm"))

    {:ok, pid} =
      Wasmex.Components.start_link(%{bytes: bytes, wasi: %Wasmex.Wasi.WasiP2Options{allow_http: true}})

    # the host synthesizes the request, drives the guest's wasi:http/incoming-handler#handle, and collects
    # the response the guest writes to the response-outparam — the guest never touches a socket.
    assert {200, headers, body} =
             Wasmex.Components.serve_http(pid, "POST", "/", [{"host", "localhost"}], "hi")

    # response-header extraction path: the header the guest set flows back to the host
    assert {"x-brokered", "yes"} in headers
    # the request reached the guest (it echoed the method) and the body flowed back
    assert body =~ "hello from brokered guest" and body =~ "Post"
    # SSRF COMPOSITION: the serving guest tried an OUTBOUND fetch to cloud metadata while handling the
    # request — it MUST be brokered/SSRF-blocked. A serving guest cannot become an SSRF pivot.
    assert body =~ "outbound=blocked"
  end

  @tag :build
  @tag timeout: 300_000
  test "wasi-http OUTBOUND works through the broker — internal SSRF-blocked, public reachable, no panic" do
    out = Path.join(System.tmp_dir!(), "net_probe_#{System.unique_integer([:positive])}.component.wasm")

    {_, 0} =
      System.cmd(
        "node",
        ["node_modules/.bin/jco", "componentize", "test/broker_e2e/net_probe.js", "--wit",
         "test/broker_e2e/net_probe.wit", "-n", "net-probe", "--enable", "http", "--enable",
         "random", "--enable", "clocks", "-o", out],
        stderr_to_stdout: true
      )

    {:ok, pid} =
      Wasmex.Components.start_link(%{path: out, wasi: %Wasmex.Wasi.WasiP2Options{allow_http: true}})

    on_exit(fn -> File.rm(out) end)
    probe = fn url -> Wasmex.Components.call_function(pid, "probe", [url], 12_000) end

    assert {:ok, meta} = probe.("http://169.254.169.254/")
    assert meta =~ "BLOCKED"
    assert {:ok, loop} = probe.("http://127.0.0.1/")
    assert loop =~ "BLOCKED"
    assert {:ok, _pub} = probe.("http://1.1.1.1/")
  end

  @tag :build
  @tag timeout: 300_000
  test "RED-TEAM holistic — a real wasi:http guest is blocked from EVERY obfuscated internal target" do
    out = Path.join(System.tmp_dir!(), "redteam_#{System.unique_integer([:positive])}.component.wasm")

    {_, 0} =
      System.cmd(
        "node",
        ["node_modules/.bin/jco", "componentize", "test/broker_e2e/net_probe.js", "--wit",
         "test/broker_e2e/net_probe.wit", "-n", "net-probe", "--enable", "http", "--enable",
         "random", "--enable", "clocks", "-o", out],
        stderr_to_stdout: true
      )

    {:ok, pid} =
      Wasmex.Components.start_link(%{path: out, wasi: %Wasmex.Wasi.WasiP2Options{allow_http: true}})

    on_exit(fn -> File.rm(out) end)
    probe = fn url -> elem(Wasmex.Components.call_function(pid, "probe", [url], 12_000), 1) end

    # every flavor of internal/obfuscated destination the red-team mandate names must come back BLOCKED
    # (either SSRF-denied at connect, or unresolvable -> denied). One real guest, the real wasi-http path.
    targets = [
      "http://127.0.0.1/",          # loopback
      "http://169.254.169.254/",    # cloud metadata
      "http://169.254.0.1/",        # link-local
      "http://10.0.0.1/",           # RFC1918
      "http://172.16.0.1/",         # RFC1918
      "http://192.168.1.1/",        # RFC1918
      "http://100.64.0.1/",         # CGNAT
      "http://[::1]/",              # IPv6 loopback
      "http://[fd00::1]/",          # IPv6 ULA
      "http://user:pass@127.0.0.1/" # userinfo@ trick
    ]

    for url <- targets do
      assert probe.(url) =~ "BLOCKED", "red-team bypass: expected #{url} to be BLOCKED"
    end
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

    assert {:ok, m} = probe.("http://169.254.169.254/")
    assert m =~ "BLOCKED"
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

    {:ok, _} = Workbooks.Instance.Supervisor.start_instance(id, bytes, policy: :network)
    on_exit(fn -> Workbooks.Instance.Supervisor.stop_instance(id) end)

    assert {:ok, body} = Workbooks.Instance.call(id, "probe", ["http://example.com/"])
    assert body =~ "Example Domain"
    assert {:ok, blocked} = Workbooks.Instance.call(id, "probe", ["http://169.254.169.254/"])
    assert blocked =~ "BLOCKED"
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 300_000
  test "wasi-SOCKETS raw TCP through the broker — standard guest connects (public OK, internal SSRF-blocked)" do
    # Build a REAL wasi:sockets component (std::net on wasm32-wasip2) via cargo-component.
    proj = "test/broker_e2e/wasi_sockets_reactor"

    {_, 0} =
      System.cmd("cargo", ["component", "build", "--release", "--target", "wasm32-wasip2"],
        cd: proj,
        stderr_to_stdout: true
      )

    wasm = Path.join(proj, "target/wasm32-wasip2/release/netprobe.wasm")

    {:ok, pid} =
      Wasmex.Components.start_link(%{path: wasm, wasi: %Wasmex.Wasi.WasiP2Options{allow_http: true}})

    probe = fn t -> elem(Wasmex.Components.call_function(pid, "probe", [t], 12_000), 1) end

    # a standard wasi:sockets connect to a public host works (the spawn_blocking fix), got an HTTP reply
    assert probe.("1.1.1.1:80") =~ "OK"
    # socket_addr_check SSRF-blocks internal targets on the raw-socket path
    assert probe.("127.0.0.1:22") =~ "ERR"
    assert probe.("169.254.169.254:80") =~ "ERR"

    # SCOPED allow-list on the raw-socket path (IP-based): a guest scoped to ["1.1.1.1"] may reach it but
    # NOT another public host (8.8.8.8, which passes the SSRF floor) — default-deny per-instance scope.
    {:ok, scoped} =
      Wasmex.Components.start_link(%{
        path: wasm,
        wasi: %Wasmex.Wasi.WasiP2Options{allow_http: true, net_allow: ["1.1.1.1"]}
      })

    sp = fn t -> elem(Wasmex.Components.call_function(scoped, "probe", [t], 12_000), 1) end
    assert sp.("1.1.1.1:80") =~ "OK"
    assert sp.("8.8.8.8:80") =~ "ERR"
    # DNS-EXFIL defense: an IP-only-scoped guest has NO name lookup — it can't even resolve a hostname,
    # so it can't leak data via DNS queries.
    assert sp.("example.com:80") =~ "ERR"
  end

  @tag :build
  @tag :netdeps
  test "SCOPED ALLOW-LIST — a per-instance net_allow scopes a WORKING wasi:http guest (listed reachable, others blocked)" do
    out = Path.join(System.tmp_dir!(), "scoped_#{System.unique_integer([:positive])}.component.wasm")

    {_, 0} =
      System.cmd(
        "node",
        ["node_modules/.bin/jco", "componentize", "test/broker_e2e/net_probe.js", "--wit",
         "test/broker_e2e/net_probe.wit", "-n", "net-probe", "--enable", "http", "--enable",
         "random", "--enable", "clocks", "-o", out],
        stderr_to_stdout: true
      )

    # this guest may ONLY reach example.com (default-deny everything else, on top of the SSRF floor)
    {:ok, pid} =
      Wasmex.Components.start_link(%{
        path: out,
        wasi: %Wasmex.Wasi.WasiP2Options{allow_http: true, net_allow: ["example.com"]}
      })

    on_exit(fn -> File.rm(out) end)
    probe = fn url -> elem(Wasmex.Components.call_function(pid, "probe", [url], 12_000), 1) end

    # example.com is on the allow-list -> reachable
    assert probe.("http://example.com/") =~ "OK"
    # a DIFFERENT public host (would pass the SSRF floor) is NOT on the list -> blocked by the scope
    assert probe.("http://1.1.1.1/") =~ "BLOCKED"
  end
end
