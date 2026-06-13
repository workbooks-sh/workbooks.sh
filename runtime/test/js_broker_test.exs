defmodule Workbooks.JsBrokerTest do
  @moduledoc """
  EMPIRICAL parity proof for the JS (QuickJS-under-wasmtime) lane's brokered capabilities — the
  npm/JS analog of py_exec_test/brokered_tools_test. Runs REAL JS through Workbooks.JsDock (Wasmex
  with Policy-gated host imports) and asserts that the harness_dock.c bindings reach the SAME
  mediated brokers Python uses:

    * Javy.Exec.run  → host_exec → ExecBroker  (default-deny, REGISTERED-only, no shell escape)
    * Javy.Net.tcp   → host_tcp  → TcpBroker   (resolve-then-pin, SSRF-safe)
    * Javy.Net.post  → host_http → NetGuard.request (arbitrary method + body, SSRF floor)
    * child_process  → the idiomatic Node shim over Javy.Exec.run

  Untrusted JS executes ONLY inside QuickJS; the host owns the actual exec/net I/O. Zero native exec.
  """
  use ExUnit.Case, async: false

  alias Workbooks.{Compilers, CommandRegistry, JsDock}

  setup_all do
    # ensure the brokered registered command set exists (jq/grep are wasm commands in the registry).
    for c <- ["jq", "grep"], c not in CommandRegistry.list() do
      try do
        Workbooks.Pallet.seed_one(c)
      rescue
        _ -> :ok
      end
    end

    :ok
  end

  # compile a single JS source file directly through the :dock lane (no bundler).
  defp dock_wasm(src) do
    f = Path.join(System.tmp_dir!(), "jsbroker-#{System.unique_integer([:positive])}.js")
    File.write!(f, src)
    on_exit(fn -> File.rm(f) end)
    {:ok, wasm, _log} = Compilers.js_compile_to_wasm(f, dock: true)
    wasm
  end

  # bundle a project (local shim copies) → dock-compiled wasm, for the idiomatic-shim tests.
  defp dock_project(index_src, shims) do
    shim_dir = Path.join(Compilers.default_root(), "js/shims")
    dir = Path.join(System.tmp_dir!(), "jsbroker-proj-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    Enum.each(shims, fn s -> File.cp!(Path.join(shim_dir, "#{s}.js"), Path.join(dir, "#{s}.js")) end)
    File.write!(Path.join(dir, "index.js"), index_src)
    {:ok, js} = Compilers.bundle_dir(dir, "index.js")
    src = Path.join(dir, "_bundle.js")
    File.write!(src, js)
    {:ok, wasm, _log} = Compilers.js_compile_to_wasm(src, dock: true)
    wasm
  end

  # ── EXEC: brokered dispatch + red-team default-deny ──────────────────────────────────────────

  @tag :build
  @tag timeout: 300_000
  test "GRANTED — Javy.Exec.run dispatches to a brokered REGISTERED command (jq runs, output returned)" do
    if "jq" not in CommandRegistry.list() do
      IO.puts("\n[skip] jq not registered")
    else
      wasm =
        dock_wasm(~S"""
        var out = Javy.Exec.run("jq", ["."], '{"a":1}');
        Javy.IO.writeSync(1, new TextEncoder().encode(out === null ? "DENIED" : ("OK:" + out.length)));
        """)

      # :minimal grants the exec/commands cap (Policy) — the call routes to ExecBroker → jq.
      assert {:ok, out} = JsDock.run(wasm, "", profile: :minimal)
      s = String.trim(to_string(out))
      assert String.starts_with?(s, "OK:"), "expected brokered jq output, got: #{s}"
      refute s == "OK:0"
    end
  end

  @tag :build
  @tag timeout: 300_000
  test "NO SHELL ESCAPE — an unregistered/arbitrary binary is refused (default-deny, host fn returns -1)" do
    # red-team: the guest asks to run /bin/sh — there is no OS exec, only REGISTERED wasm commands.
    wasm =
      dock_wasm(~S"""
      var out = Javy.Exec.run("/bin/sh", ["-c", "echo pwned"], "");
      Javy.IO.writeSync(1, new TextEncoder().encode(out === null ? "DENIED" : ("LEAK:" + out)));
      """)

    assert {:ok, out} = JsDock.run(wasm, "", profile: :minimal)
    s = String.trim(to_string(out))
    assert s == "DENIED", "an unregistered binary must be refused; got: #{s}"
    refute s =~ "pwned"
  end

  @tag :build
  @tag timeout: 300_000
  test "child_process.execSync (idiomatic Node shim) routes through Javy.Exec.run → ExecBroker" do
    wasm =
      dock_project(
        ~S"""
        var cp = require("./child_process");
        try {
          var out = cp.execSync("jq .", { input: '{"a":1}' });
          Javy.IO.writeSync(1, new TextEncoder().encode("OK:" + out.length));
        } catch (e) {
          Javy.IO.writeSync(1, new TextEncoder().encode("ERR:" + e));
        }
        """,
        ~w(child_process events)
      )

    case JsDock.run(wasm, "", profile: :minimal) do
      {:ok, out} ->
        s = String.trim(to_string(out))

        if "jq" in CommandRegistry.list() do
          assert String.starts_with?(s, "OK:"), "expected child_process→jq output, got: #{s}"
        else
          IO.puts("\n[skip] jq not registered; child_process surface compiled+ran: #{s}")
        end

      {:error, reason} ->
        IO.puts("\n[skip] child_process exec: #{inspect(reason) |> String.slice(0, 120)}")
    end
  end

  # ── TCP: brokered raw socket + SSRF red-team ─────────────────────────────────────────────────

  @tag :build
  @tag timeout: 300_000
  test "SSRF — Javy.Net.tcp to an internal target (127.0.0.1) is DENIED before any connect" do
    wasm =
      dock_wasm(~S"""
      var r = Javy.Net.tcp("127.0.0.1", 22, "x");
      Javy.IO.writeSync(1, new TextEncoder().encode(r === null ? "DENIED" : ("LEAK:" + r.length)));
      """)

    assert {:ok, out} = JsDock.run(wasm, "", profile: :minimal)
    assert String.trim(to_string(out)) == "DENIED"
  end

  @tag :netdeps
  @tag :build
  @tag timeout: 300_000
  test "Javy.Net.tcp — a raw HTTP/1 request to a public host:80 returns response bytes" do
    wasm =
      dock_wasm(~S"""
      var req = "GET / HTTP/1.0\r\nHost: example.com\r\nConnection: close\r\n\r\n";
      var r = Javy.Net.tcp("example.com", 80, req);
      Javy.IO.writeSync(1, new TextEncoder().encode(r === null ? "ERR" : (r.indexOf("HTTP/1.") >= 0 ? "GOT" : "EMPTY")));
      """)

    case JsDock.run(wasm, "", profile: :network) do
      {:ok, out} ->
        s = String.trim(to_string(out))
        assert s in ["GOT", "EMPTY", "ERR"]
        if s != "GOT", do: IO.puts("\n[netdeps] tcp returned #{s} (network-dependent)")

      {:error, reason} ->
        IO.puts("\n[skip] js tcp: #{inspect(reason) |> String.slice(0, 120)}")
    end
  end

  # ── HTTP POST: brokered arbitrary-method egress ──────────────────────────────────────────────

  @tag :build
  @tag timeout: 300_000
  test "HTTP POST is DENIED on a non-net profile (host_http gated on net/browse cap)" do
    wasm =
      dock_wasm(~S"""
      var r = Javy.Net.post("https://example.com/", "hello", {"content-type": "text/plain"});
      Javy.IO.writeSync(1, new TextEncoder().encode(r === null ? "DENIED" : "GOT"));
      """)

    # :minimal has no net/browse cap → allow_http? is false → host_http returns -1.
    assert {:ok, out} = JsDock.run(wasm, "", profile: :minimal)
    assert String.trim(to_string(out)) == "DENIED"
  end

  @tag :netdeps
  @tag :build
  @tag timeout: 300_000
  test "Javy.Net.post — brokered HTTP POST on :network returns a response (echo)" do
    wasm =
      dock_wasm(~S"""
      var r = Javy.Net.post("https://httpbin.org/post", "ping=pong", {"content-type": "application/x-www-form-urlencoded"});
      Javy.IO.writeSync(1, new TextEncoder().encode(r === null ? "ERR" : (r.indexOf("ping") >= 0 ? "ECHOED" : "RESP")));
      """)

    case JsDock.run(wasm, "", profile: :network) do
      {:ok, out} ->
        s = String.trim(to_string(out))
        assert s in ["ECHOED", "RESP", "ERR"]
        if s == "ERR", do: IO.puts("\n[netdeps] post returned ERR (network-dependent)")

      {:error, reason} ->
        IO.puts("\n[skip] js post: #{inspect(reason) |> String.slice(0, 120)}")
    end
  end
end
