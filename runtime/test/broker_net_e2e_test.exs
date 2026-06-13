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
  @tag :netdeps
  @tag timeout: 300_000
  test "APP-HOST — a REAL HTTP server drives a standard wasi:http component per request" do
    proj = "test/broker_e2e/wasi_http_handler"

    {_, 0} =
      System.cmd("cargo", ["component", "build", "--release", "--target", "wasm32-wasip2"],
        cd: proj,
        stderr_to_stdout: true
      )

    bytes = File.read!(Path.join(proj, "target/wasm32-wasip2/release/httpguest.wasm"))

    {:ok, pid} =
      Wasmex.Components.start_link(%{bytes: bytes, wasi: %Wasmex.Wasi.WasiP2Options{allow_http: true}})

    port = 45_000 + rem(System.unique_integer([:positive]), 4_000)

    # the HOST owns the listening socket; Bandit drives each request into the wasi:http component
    {:ok, srv} =
      Bandit.start_link(
        plug: {Workbooks.ServeBroker.ComponentPlug, pid: pid},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: port
      )

    on_exit(fn -> Process.exit(srv, :normal) end)
    Process.sleep(150)
    _ = Application.ensure_all_started(:inets)

    # a REAL HTTP GET over a real socket -> the component handles it -> its response comes back
    {:ok, {{_, status, _}, hdrs, body}} =
      :httpc.request(:get, {~c"http://127.0.0.1:#{port}/", []}, [], body_format: :binary)

    body = to_string(body)
    assert status == 200
    assert {~c"x-brokered", ~c"yes"} in hdrs
    assert body =~ "hello from brokered guest"
    # and the component's own outbound (during handling) was still SSRF-brokered
    assert body =~ "outbound=blocked"
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 300_000
  test "APP-HOST concurrency — a POOL of wasi:http instances serves concurrent requests correctly" do
    proj = "test/broker_e2e/wasi_http_handler"

    {_, 0} =
      System.cmd("cargo", ["component", "build", "--release", "--target", "wasm32-wasip2"],
        cd: proj,
        stderr_to_stdout: true
      )

    bytes = File.read!(Path.join(proj, "target/wasm32-wasip2/release/httpguest.wasm"))

    # a pool of 4 wasi:http instances behind the app-host
    pids =
      for _ <- 1..4 do
        {:ok, p} =
          Wasmex.Components.start_link(%{bytes: bytes, wasi: %Wasmex.Wasi.WasiP2Options{allow_http: true}})

        p
      end

    on_exit(fn -> Enum.each(pids, &Process.exit(&1, :normal)) end)
    port = 45_000 + rem(System.unique_integer([:positive]), 4_000)

    {:ok, srv} =
      Bandit.start_link(
        plug: {Workbooks.ServeBroker.ComponentPlug, pids: pids},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: port
      )

    on_exit(fn -> Process.exit(srv, :normal) end)
    Process.sleep(150)
    _ = Application.ensure_all_started(:inets)
    url = ~c"http://127.0.0.1:#{port}/"

    # 20 concurrent real HTTP requests across the pool — every one must succeed with the right response
    results =
      1..20
      |> Task.async_stream(
        fn _ ->
          {:ok, {{_, status, _}, _h, body}} =
            :httpc.request(:get, {url, []}, [], body_format: :binary)

          {status, to_string(body)}
        end,
        max_concurrency: 20,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, r} -> r end)

    assert length(results) == 20
    assert Enum.all?(results, fn {s, b} -> s == 200 and b =~ "hello from brokered guest" end)
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 300_000
  test "APP-HOST fresh-per-request — each request gets an ISOLATED wasi:http instance (correct serve model)" do
    proj = "test/broker_e2e/wasi_http_handler"

    {_, 0} =
      System.cmd("cargo", ["component", "build", "--release", "--target", "wasm32-wasip2"],
        cd: proj,
        stderr_to_stdout: true
      )

    bytes = File.read!(Path.join(proj, "target/wasm32-wasip2/release/httpguest.wasm"))

    # compile ONCE into a shared engine; each request instantiates a FRESH store+instance (isolation)
    wasi = %Wasmex.Wasi.WasiP2Options{allow_http: true}
    {:ok, engine} = Wasmex.Engine.new(%Wasmex.EngineConfig{})
    {:ok, s0} = Wasmex.Components.Store.new_wasi(wasi, nil, engine)
    {:ok, component} = Wasmex.Components.Component.new(s0, bytes)

    port = 45_000 + rem(System.unique_integer([:positive]), 4_000)

    {:ok, srv} =
      Bandit.start_link(
        plug: {Workbooks.ServeBroker.ComponentPlug, component: component, engine: engine},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: port
      )

    on_exit(fn -> Process.exit(srv, :normal) end)
    Process.sleep(150)
    _ = Application.ensure_all_started(:inets)
    url = ~c"http://127.0.0.1:#{port}/"

    # 20 concurrent requests, EACH a fresh isolated instance — all succeed, no recompile, no serialization
    results =
      1..20
      |> Task.async_stream(
        fn _ ->
          {:ok, {{_, status, _}, _h, body}} =
            :httpc.request(:get, {url, []}, [], body_format: :binary)

          {status, to_string(body)}
        end,
        max_concurrency: 20,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, r} -> r end)

    assert length(results) == 20
    assert Enum.all?(results, fn {s, b} -> s == 200 and b =~ "hello from brokered guest" end)
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

    # wb-8w8x: HTTPS through the IP-PINNED wasi:http handler — real content arrives (pin + cert validation
    # against the hostname both work), and an internal https target is still SSRF-blocked.
    assert {:ok, https_body} = probe.("https://example.com/")
    assert https_body =~ "Example Domain"
    assert {:ok, https_blocked} = probe.("https://169.254.169.254/")
    assert https_blocked =~ "BLOCKED"
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

    # STANDARD wasi:sockets UDP path (keystone goal 2, now also generalized for UDP): a real std::net::
    # UdpSocket DNS query to a PUBLIC resolver works through the broker, and socket_addr_check SSRF-blocks an
    # INTERNAL UDP target — the sibling of the raw-TCP proof, never adversarially tested until now.
    assert probe.("udp:1.1.1.1:53") =~ ~r/OK dns ancount=[1-9]/
    assert probe.("udp:127.0.0.1:53") =~ "ERR"
    assert probe.("udp:169.254.169.254:53") =~ "ERR"
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

  @tag :build
  @tag :netdeps
  @tag timeout: 300_000
  test "APP-HOST inbound rate floor — a flooding client is 429'd (per-client DoS quota)" do
    proj = "test/broker_e2e/wasi_http_handler"

    {_, 0} =
      System.cmd("cargo", ["component", "build", "--release", "--target", "wasm32-wasip2"],
        cd: proj,
        stderr_to_stdout: true
      )

    bytes = File.read!(Path.join(proj, "target/wasm32-wasip2/release/httpguest.wasm"))

    {:ok, pid} =
      Wasmex.Components.start_link(%{bytes: bytes, wasi: %Wasmex.Wasi.WasiP2Options{allow_http: true}})

    port = 45_000 + rem(System.unique_integer([:positive]), 4_000)

    # a per-client budget of 1 request / window
    {:ok, srv} =
      Bandit.start_link(
        plug: {Workbooks.ServeBroker.ComponentPlug, pid: pid, rate: {1, 60_000}},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: port
      )

    on_exit(fn -> Process.exit(srv, :normal) end)
    Process.sleep(150)
    _ = Application.ensure_all_started(:inets)
    url = ~c"http://127.0.0.1:#{port}/"

    # 1st request is within budget; the 2nd from the same client exceeds it -> 429
    {:ok, {{_, s1, _}, _, _}} = :httpc.request(:get, {url, []}, [], body_format: :binary)
    {:ok, {{_, s2, _}, _, _}} = :httpc.request(:get, {url, []}, [], body_format: :binary)

    assert s1 == 200
    assert s2 == 429
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 600_000
  test "APP-HOST soak — sustained fresh-per-request serving is memory-stable (no per-request resource leak)" do
    proj = "test/broker_e2e/wasi_http_handler"

    {_, 0} =
      System.cmd("cargo", ["component", "build", "--release", "--target", "wasm32-wasip2"],
        cd: proj,
        stderr_to_stdout: true
      )

    bytes = File.read!(Path.join(proj, "target/wasm32-wasip2/release/httpguest.wasm"))

    # compile ONCE; each "request" instantiates a fresh store+instance (the production serve model)
    wasi = %Wasmex.Wasi.WasiP2Options{allow_http: true}
    {:ok, engine} = Wasmex.Engine.new(%Wasmex.EngineConfig{})
    {:ok, s0} = Wasmex.Components.Store.new_wasi(wasi, nil, engine)
    {:ok, component} = Wasmex.Components.Component.new(s0, bytes)

    serve = fn ->
      {:ok, store} = Wasmex.Components.Store.new_wasi(wasi, nil, engine)
      {:ok, inst} = Wasmex.Components.Instance.new(store, component, %{})
      Wasmex.Components.Instance.serve_http(inst, "GET", "/", [{"host", "localhost"}], "")
    end

    # warm up, then baseline memory after a GC
    for _ <- 1..50, do: serve.()
    :erlang.garbage_collect()
    Process.sleep(100)
    mem0 = :erlang.memory(:total)

    # sustained churn: 2000 fresh instances created + dropped
    oks =
      Enum.reduce(1..2000, 0, fn _, acc ->
        case serve.() do
          {200, _h, _b} -> acc + 1
          _ -> acc
        end
      end)

    :erlang.garbage_collect()
    Process.sleep(200)
    mem1 = :erlang.memory(:total)

    # correctness held under sustained load
    assert oks == 2000
    # and the runtime didn't balloon — 2000 fresh instances must be reclaimed, not leaked. A real leak would
    # be ~GBs (instance linear memory × 2000); a healthy steady state is ~one instance's worth.
    growth_mb = (mem1 - mem0) / 1_048_576

    assert growth_mb < 64,
           "memory grew #{Float.round(growth_mb, 1)} MB over 2000 fresh-per-request serves — likely a resource leak"
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 300_000
  test "APP-HOST mid-flight revocation — a revoked hosted app is refused (503), server keeps running" do
    proj = "test/broker_e2e/wasi_http_handler"

    {_, 0} =
      System.cmd("cargo", ["component", "build", "--release", "--target", "wasm32-wasip2"],
        cd: proj,
        stderr_to_stdout: true
      )

    bytes = File.read!(Path.join(proj, "target/wasm32-wasip2/release/httpguest.wasm"))

    {:ok, pid} =
      Wasmex.Components.start_link(%{bytes: bytes, wasi: %Wasmex.Wasi.WasiP2Options{allow_http: true}})

    sid = "apphost-#{System.unique_integer([:positive])}"
    port = 45_000 + rem(System.unique_integer([:positive]), 4_000)

    {:ok, srv} =
      Bandit.start_link(
        plug: {Workbooks.ServeBroker.ComponentPlug, pid: pid, serve_id: sid},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: port
      )

    on_exit(fn -> Process.exit(srv, :normal) end)
    Process.sleep(150)
    _ = Application.ensure_all_started(:inets)
    url = ~c"http://127.0.0.1:#{port}/"
    req = fn -> :httpc.request(:get, {url, []}, [], body_format: :binary) |> elem(1) |> elem(0) |> elem(1) end

    # serving normally -> revoke (mid-flight) -> refused -> unrevoke -> serving again
    assert req.() == 200
    :ok = Workbooks.Revocation.revoke(sid)
    assert req.() == 503
    :ok = Workbooks.Revocation.unrevoke(sid)
    assert req.() == 200
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 300_000
  test "STREAMING serve NIF (wb-t3sq) — response body arrives as start / data* / done messages" do
    proj = "test/broker_e2e/wasi_http_handler"

    {_, 0} =
      System.cmd("cargo", ["component", "build", "--release", "--target", "wasm32-wasip2"],
        cd: proj,
        stderr_to_stdout: true
      )

    bytes = File.read!(Path.join(proj, "target/wasm32-wasip2/release/httpguest.wasm"))
    wasi = %Wasmex.Wasi.WasiP2Options{allow_http: true}
    {:ok, engine} = Wasmex.Engine.new(%Wasmex.EngineConfig{})
    {:ok, s0} = Wasmex.Components.Store.new_wasi(wasi, nil, engine)
    {:ok, component} = Wasmex.Components.Component.new(s0, bytes)
    {:ok, store} = Wasmex.Components.Store.new_wasi(wasi, nil, engine)
    {:ok, inst} = Wasmex.Components.Instance.new(store, component, %{})

    ref = make_ref()

    :ok =
      Wasmex.Components.Instance.serve_http_stream(
        inst,
        "GET",
        "/",
        [{"host", "localhost"}],
        "",
        self(),
        ref
      )

    # the DirtyCpu NIF ran synchronously, queuing the stream messages to our mailbox
    assert_receive {^ref, :stream_start, 200, headers}, 5_000
    assert is_list(headers)
    {body, _frames} = collect_stream(ref, "", 0)
    assert body =~ "hello from brokered guest"
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 120_000
  test "STREAMING large body (wb-95o6) — a 256KB response streams in MULTIPLE frames, NO deadlock" do
    proj = "test/broker_e2e/wasi_http_handler"

    {_, 0} =
      System.cmd("cargo", ["component", "build", "--release", "--target", "wasm32-wasip2"],
        cd: proj,
        stderr_to_stdout: true
      )

    bytes = File.read!(Path.join(proj, "target/wasm32-wasip2/release/httpguest.wasm"))
    wasi = %Wasmex.Wasi.WasiP2Options{allow_http: true}
    {:ok, engine} = Wasmex.Engine.new(%Wasmex.EngineConfig{})
    {:ok, s0} = Wasmex.Components.Store.new_wasi(wasi, nil, engine)
    {:ok, component} = Wasmex.Components.Component.new(s0, bytes)
    {:ok, store} = Wasmex.Components.Store.new_wasi(wasi, nil, engine)
    {:ok, inst} = Wasmex.Components.Instance.new(store, component, %{})

    ref = make_ref()

    # /stream makes the guest emit 256_000 bytes in 64 flushes — would DEADLOCK the old serve; the concurrent
    # drain handles it. Run under a Task so a regression shows as a fast failure, not a hung suite.
    task =
      Task.async(fn ->
        :ok =
          Wasmex.Components.Instance.serve_http_stream(
            inst,
            "GET",
            "/stream",
            [{"host", "localhost"}],
            "",
            self(),
            ref
          )

        assert_receive {^ref, :stream_start, 200, _headers}, 30_000
        collect_stream(ref, "", 0)
      end)

    {body, frames} = Task.await(task, 60_000)

    assert byte_size(body) == 256_000
    assert frames > 1
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 120_000
  test "BUFFERED serve_http large body (wb-95o6) — a 256KB response returns, NO deadlock" do
    proj = "test/broker_e2e/wasi_http_handler"

    {_, 0} =
      System.cmd("cargo", ["component", "build", "--release", "--target", "wasm32-wasip2"],
        cd: proj,
        stderr_to_stdout: true
      )

    bytes = File.read!(Path.join(proj, "target/wasm32-wasip2/release/httpguest.wasm"))
    wasi = %Wasmex.Wasi.WasiP2Options{allow_http: true}
    {:ok, engine} = Wasmex.Engine.new(%Wasmex.EngineConfig{})
    {:ok, s0} = Wasmex.Components.Store.new_wasi(wasi, nil, engine)
    {:ok, component} = Wasmex.Components.Component.new(s0, bytes)
    {:ok, store} = Wasmex.Components.Store.new_wasi(wasi, nil, engine)
    {:ok, inst} = Wasmex.Components.Instance.new(store, component, %{})

    # the buffered path used to deadlock identically on a body over the wasi-http buffer; run under a Task so a
    # regression is a fast failure, not a hung suite.
    task =
      Task.async(fn ->
        Wasmex.Components.Instance.serve_http(inst, "GET", "/stream", [{"host", "localhost"}], "")
      end)

    {status, _headers, body} = Task.await(task, 60_000)

    assert status == 200
    assert byte_size(body) == 256_000
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 300_000
  test "APP-HOST streaming — chunked transfer through Bandit to a real client (wb-t3sq)" do
    proj = "test/broker_e2e/wasi_http_handler"

    {_, 0} =
      System.cmd("cargo", ["component", "build", "--release", "--target", "wasm32-wasip2"],
        cd: proj,
        stderr_to_stdout: true
      )

    bytes = File.read!(Path.join(proj, "target/wasm32-wasip2/release/httpguest.wasm"))
    wasi = %Wasmex.Wasi.WasiP2Options{allow_http: true}
    {:ok, engine} = Wasmex.Engine.new(%Wasmex.EngineConfig{})
    {:ok, s0} = Wasmex.Components.Store.new_wasi(wasi, nil, engine)
    {:ok, component} = Wasmex.Components.Component.new(s0, bytes)

    port = 45_000 + rem(System.unique_integer([:positive]), 4_000)

    {:ok, srv} =
      Bandit.start_link(
        plug: {Workbooks.ServeBroker.ComponentPlug, component: component, engine: engine, stream: true},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: port
      )

    on_exit(fn -> Process.exit(srv, :normal) end)
    Process.sleep(150)

    # raw socket: :httpc de-chunks and hides Transfer-Encoding, so read the wire bytes directly to PROVE the
    # response was streamed via chunked transfer (send_chunked) rather than buffered with a Content-Length.
    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw])

    :ok = :gen_tcp.send(sock, "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
    raw = recv_all(sock, "")
    :gen_tcp.close(sock)

    assert raw =~ "200"
    assert raw =~ ~r/transfer-encoding:\s*chunked/i
    assert raw =~ "hello from brokered guest"
  end

  defp recv_all(sock, acc) do
    case :gen_tcp.recv(sock, 0, 5_000) do
      {:ok, data} -> recv_all(sock, acc <> data)
      {:error, _} -> acc
    end
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 120_000
  test "COMPUTE-DoS bound (wb-95o6) — a guest spinning in handle() is TRAPPED by the epoch deadline" do
    proj = "test/broker_e2e/wasi_http_handler"

    {_, 0} =
      System.cmd("cargo", ["component", "build", "--release", "--target", "wasm32-wasip2"],
        cd: proj,
        stderr_to_stdout: true
      )

    bytes = File.read!(Path.join(proj, "target/wasm32-wasip2/release/httpguest.wasm"))
    wasi = %Wasmex.Wasi.WasiP2Options{allow_http: true}
    # an EPOCH engine (the 1s ticker runs) so the serve store can set a wall-clock deadline
    {:ok, engine} = Wasmex.Engine.new(%Wasmex.EngineConfig{epoch_interruption: true})
    {:ok, s0} = Wasmex.Components.Store.new_wasi(wasi, nil, engine)
    {:ok, component} = Wasmex.Components.Component.new(s0, bytes)
    {:ok, store} = Wasmex.Components.Store.new_wasi(wasi, nil, engine)
    {:ok, inst} = Wasmex.Components.Instance.new(store, component, %{})

    ref = make_ref()

    # /spin makes the guest loop forever before setting the response. With a 3s epoch deadline the call MUST
    # trap (not hang). Run under a Task so a regression is a fast failure, not a hung suite.
    task =
      Task.async(fn ->
        try do
          Wasmex.Components.Instance.serve_http_stream(
            inst,
            "GET",
            "/spin",
            [{"host", "localhost"}],
            "",
            self(),
            ref,
            3
          )
        rescue
          e -> {:trapped, Exception.message(e)}
        catch
          kind, e -> {:trapped, "#{kind}: #{inspect(e)}"}
        end
      end)

    # without the epoch trap this would hang to the 120s test timeout; with it, it returns within ~10s
    result = Task.yield(task, 30_000)
    Task.shutdown(task, :brutal_kill)
    assert match?({:ok, _}, result), "spinning guest must be trapped by the epoch deadline, not hang"
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 120_000
  test "APP-HOST compute-DoS (wb-95o6) — a spinning guest is bounded (500); the server keeps serving" do
    proj = "test/broker_e2e/wasi_http_handler"

    {_, 0} =
      System.cmd("cargo", ["component", "build", "--release", "--target", "wasm32-wasip2"],
        cd: proj,
        stderr_to_stdout: true
      )

    bytes = File.read!(Path.join(proj, "target/wasm32-wasip2/release/httpguest.wasm"))
    wasi = %Wasmex.Wasi.WasiP2Options{allow_http: true}
    {:ok, engine} = Wasmex.Engine.new(%Wasmex.EngineConfig{epoch_interruption: true})
    {:ok, s0} = Wasmex.Components.Store.new_wasi(wasi, nil, engine)
    {:ok, component} = Wasmex.Components.Component.new(s0, bytes)

    port = 45_000 + rem(System.unique_integer([:positive]), 4_000)

    {:ok, srv} =
      Bandit.start_link(
        plug:
          {Workbooks.ServeBroker.ComponentPlug,
           component: component, engine: engine, stream: true, epoch_deadline: 3},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: port
      )

    on_exit(fn -> Process.exit(srv, :normal) end)
    Process.sleep(150)
    _ = Application.ensure_all_started(:inets)

    # the spinning guest is bounded by the epoch deadline (the serve completes in ~8s, freeing the worker +
    # NIF threads — no leak); the request returns an error status, NOT an infinite hang.
    spin = ~c"http://127.0.0.1:#{port}/spin"

    {:ok, {{_, spin_status, _}, _, _}} =
      :httpc.request(:get, {spin, []}, [{:timeout, 30_000}], body_format: :binary)

    # the handler is monitored: a trapped guest that completes without a usable response fails FAST (500/502),
    # not via the slow 504 receive backstop.
    assert spin_status in [500, 502], "spinning guest must fail fast, got #{spin_status}"

    # and the server is still up — a normal request after the attack succeeds
    ok = ~c"http://127.0.0.1:#{port}/"
    {:ok, {{_, ok_status, _}, _, ok_body}} = :httpc.request(:get, {ok, []}, [], body_format: :binary)
    assert ok_status == 200
    assert to_string(ok_body) =~ "hello from brokered guest"
  end

  defp collect_stream(ref, acc, frames) do
    receive do
      {^ref, :stream_data, chunk} -> collect_stream(ref, acc <> chunk, frames + 1)
      {^ref, :stream_done} -> {acc, frames}
      {^ref, :stream_aborted} -> {acc, frames}
    after
      5_000 -> flunk("stream did not complete")
    end
  end
end
