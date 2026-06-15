defmodule Workbooks.JsNodeExecTest do
  @moduledoc """
  SLICE 1 gate (wb-b9xv.9) — the StarlingMonkey eval lane gets (1) async stdout capture and (2) a
  brokered tool-exec path, proven EMPIRICALLY on the live engine.

  (1) ASYNC CAPTURE — `JsEngine.run_node/2` wraps the user body in an awaited async IIFE + idle-drains
      the event loop (mirroring console_capture/1), so output from `await`ed work (setTimeout chains,
      fetch, brokered exec) and from `console.log` reaches stdout — not just synchronous top-level writes.

  (2) BROKERED EXEC — `require('child_process')` on this lane dispatches over a guest `fetch()` to the
      fixed internal sentinel `wb-exec.internal` (pinned past the SSRF floor by the WasiHttpView override
      to the in-process ExecLoopback listener) → `Workbooks.ExecBroker.exec/4` → CommandRegistry (the wasm
      CLIs). There is NO native exec: the guest never spawns; the host runs an allowlisted wasm command.
      Default-deny holds (allow:false / unregistered / no-grant all refuse); the SSRF floor is unbreached
      (a non-sentinel loopback fetch is still denied).

  `:build` — needs the SM eval-host (build/cache/jsengine/eval-host-023.wasm); skips otherwise.
  """
  use ExUnit.Case, async: false
  alias Workbooks.{JsEngine, CommandRegistry}

  setup_all do
    # the SSRF-floor probe hits the loopback listener's bound port directly, so ensure it's running
    # (idempotent). The exec/fs ops in the other tests now ride the host-import and don't need it, but the
    # direct-port probe does.
    _ = Workbooks.ExecLoopback.start_listener()
    {:ok, ready?: match?({:ok, _}, JsEngine.build_host())}
  end

  # ── (1) async stdout capture ─────────────────────────────────────────────────────────────────

  @tag :build
  @tag timeout: 60_000
  test "async output (setTimeout chain + console.log) reaches stdout", %{ready?: ready?} do
    if not ready? do
      IO.puts("\n[skip] SM eval-host not built")
    else
      src = ~S"""
      (async () => {
        await new Promise(r => setTimeout(r, 20));
        process.stdout.write("after-await\n");
        await Promise.resolve();
        console.log("console-after");
        await new Promise(r => setTimeout(r, 20));
        console.log("final");
      })();
      """

      assert {:ok, %{stdout: out, exit_code: 0}} = JsEngine.run_node(src)
      assert out == "after-await\nconsole-after\nfinal\n"
    end
  end

  # ── (2) brokered exec: GRANTED ───────────────────────────────────────────────────────────────

  @tag :build
  @tag timeout: 120_000
  test "GRANTED — execFileSync('grep', …) routes through the broker to a registered wasm CLI", %{ready?: ready?} do
    cond do
      not ready? ->
        IO.puts("\n[skip] SM eval-host not built")

      "grep" not in CommandRegistry.list() ->
        IO.puts("\n[skip] grep not registered")

      true ->
        src = ~S"""
        const cp = require('child_process');
        const out = await cp.execFileSync('grep', ['hello'], { input: 'hello world\nbye\nhello again\n' });
        process.stdout.write('GREP:' + out);
        """

        assert {:ok, %{stdout: out, exit_code: 0}} =
                 JsEngine.run_node(src, exec: [allow: true, principal: "test-tenant"])

        assert out =~ "GREP:"
        assert out =~ "hello world"
        assert out =~ "hello again"
        refute out =~ "bye"
    end
  end

  # ── (2) brokered exec: DEFAULT-DENY (the security spine) ─────────────────────────────────────

  @tag :build
  @tag timeout: 120_000
  test "DENIED — an unregistered command is refused", %{ready?: ready?} do
    if not ready? do
      IO.puts("\n[skip] SM eval-host not built")
    else
      src = ~S"""
      const cp = require('child_process');
      try { await cp.execFileSync('definitely-not-registered', []); process.stdout.write('UNEXPECTED'); }
      catch (e) { process.stdout.write('REFUSED:' + e.message); }
      """

      assert {:ok, %{stdout: out}} = JsEngine.run_node(src, exec: [allow: true, principal: "test-tenant"])
      assert out =~ "REFUSED:"
      refute out =~ "UNEXPECTED"
    end
  end

  @tag :build
  @tag timeout: 120_000
  test "DENIED — allow:false refuses even a registered command (default-deny)", %{ready?: ready?} do
    cond do
      not ready? ->
        IO.puts("\n[skip] SM eval-host not built")

      "grep" not in CommandRegistry.list() ->
        IO.puts("\n[skip] grep not registered")

      true ->
        src = ~S"""
        const cp = require('child_process');
        try { await cp.execFileSync('grep', ['x'], { input: 'x\n' }); process.stdout.write('RAN'); }
        catch (e) { process.stdout.write('DENY:' + e.message); }
        """

        assert {:ok, %{stdout: out}} = JsEngine.run_node(src, exec: [allow: false])
        assert out =~ "DENY:"
        refute out =~ "RAN"
    end
  end

  @tag :build
  @tag timeout: 60_000
  test "NO GRANT — require('child_process') throws (no silent capability)", %{ready?: ready?} do
    if not ready? do
      IO.puts("\n[skip] SM eval-host not built")
    else
      src = ~S"""
      try { require('child_process'); process.stdout.write('LOADED'); }
      catch (e) { process.stdout.write('NOCAP:' + e.message); }
      """

      assert {:ok, %{stdout: out}} = JsEngine.run_node(src)
      assert out =~ "NOCAP:"
      assert out =~ "Cannot find module"
      refute out =~ "LOADED"
    end
  end

  # ── (2) SSRF floor unbreached ────────────────────────────────────────────────────────────────

  @tag :build
  @tag timeout: 60_000
  test "SSRF floor intact — a non-sentinel loopback fetch is still denied", %{ready?: ready?} do
    if not ready? do
      IO.puts("\n[skip] SM eval-host not built")
    else
      port = Workbooks.ExecLoopback.port()

      src = """
      try { const r = await fetch('http://127.0.0.1:#{port}/__wb/exec'); process.stdout.write('LEAK:' + r.status); }
      catch (e) { process.stdout.write('SSRF-DENIED'); }
      """

      assert {:ok, %{stdout: out}} = JsEngine.run_node(src, exec: [allow: true, principal: "test-tenant"])
      assert out == "SSRF-DENIED"
    end
  end
end
