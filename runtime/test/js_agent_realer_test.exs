defmodule Workbooks.JsAgentRealerTest do
  @moduledoc """
  A REAL-ER headless JS coding agent on the PERSISTENT StarlingMonkey instance (wb-b9xv), driven end-to-end
  on the LIVE engine — past harness_min.js. Exercises the now-supported surface:

    (a) fs     — require('node:fs')/'fs/promises' WRITES + READS files CONFINED to the granted workdir
                 (PLAN.md / ANSWER.txt land as REAL host files inside the workdir, host-side verified;
                 a `..` traversal escape is refused mid-session);
    (b) stream — child_process.spawn drives the streaming protocol; the agent consumes INCREMENTAL stdout
                 chunks (streamChunks > 1, >1MB — NOT one buffered blob);
    (c) llm    — fetch() the LLM-shaped endpoint (Claude-Messages mock on the pinned sentinel);
    (d) async  — a MULTI-STEP turn (fs-write -> fs-read -> llm -> brokered-exec tool -> llm -> fs-write) whose
                 conversation + scratchpad + phase cursor accumulate on ONE live heap.

  The fs grant + exec grant ride ONE session token (one mint, one revoke).

  RUNTIME SHAPE (KEYSTONE host-import): each host-seam op (fs/llm/exec/stream) now goes through the
  SYNCHRONOUS `wb:jseval/broker.host-call` import (`globalThis.__wbHostCall`), NOT a guest wasi:http fetch.
  The host performs the op and returns IN-CALL, so no async future ever straddles a run() boundary — the
  multi-step turn drives across MANY entries on ONE resident instance with NO recycle, heap state accumulating
  throughout. This test PROVES the full turn + a SECOND turn on the same instance (no recycle) + the streaming
  capstone + that recycle still works + workdir confinement, all on the LIVE engine. (The legacy wasi:http
  re-entry ceiling is characterized separately in harness_session_test's "the measured wall".)

  `:build` — needs the SM eval-host. `:pallet` — needs coreutils.wasm (the streaming producer) seeded via
  Pallet. Skips cleanly otherwise. async: false (shared loopback listener + registered CLIs).
  """
  use ExUnit.Case, async: false
  alias Workbooks.{HarnessSession, JsEngine, CommandRegistry, ExecLoopback, Pallet}

  @agent_js Path.join(__DIR__, "fixtures/agent_realer.js")

  setup_all do
    System.put_env("WB_HARNESS", "1")
    {:ok, _} = Task.start(fn -> ExecLoopback.start_listener(); Process.sleep(:infinity) end)
    wait_for_loopback()
    System.delete_env("WB_HARNESS")
    coreutils? = Pallet.seed_one("coreutils") == :ok and "coreutils" in CommandRegistry.list()
    {:ok, ready?: match?({:ok, _}, JsEngine.build_host()), coreutils?: coreutils?}
  end

  defp wait_for_loopback(tries \\ 200) do
    cond do
      tries <= 0 -> :ok
      match?(p when is_integer(p), :persistent_term.get({ExecLoopback, :port}, nil)) -> :ok
      true -> Process.sleep(10); wait_for_loopback(tries - 1)
    end
  end

  defp workdir do
    d = Path.join(System.tmp_dir!(), "wb-agent-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(d) end)
    d
  end

  # Drive the whole non-streaming turn (the LLM tool-loop + fs I/O) in ONE run() entry: loop __agent.step()
  # through its phases until it reaches the "stream" capstone, accumulating heap state across the phases.
  # Returns the last phase result map. (One entry can issue MANY sequential awaited fetches; it's RE-ENTRY
  # after such an entry that the wasi:http component refuses — handled by recycle/1 between turns.)
  defp drive_turn(pid, prompt) do
    js = """
    (async () => {
      let r, first = #{Jason.encode!(prompt)};
      for (let i = 0; i < 12 && globalThis.__agent.phase !== 'stream'; i++) {
        r = await globalThis.__agent.step(i === 0 ? first : '');
      }
      return JSON.stringify({ last: r, phase: globalThis.__agent.phase, msgs: globalThis.__agent.messages.length,
                              files: globalThis.__agent.files, log: globalThis.__agent.log.length,
                              toolCalls: globalThis.__agent.toolCalls, answer: globalThis.__agent.answer });
    })()
    """

    {:ok, out} = HarnessSession.eval(pid, js, timeout: 180_000)
    Jason.decode!(out)
  end

  # Drive the streaming capstone in its own (terminal) entry; returns its proof map.
  defp drive_stream(pid) do
    {:ok, out} =
      HarnessSession.eval(pid, "(async()=>JSON.stringify(await globalThis.__agent.step('')))()", timeout: 180_000)

    Jason.decode!(out)
  end

  @tag :build
  @tag :pallet
  @tag timeout: 300_000
  test "real-er agent: full fs+LLM multi-step turn on a persistent instance, streaming capstone, recycle, second turn",
       %{ready?: ready?, coreutils?: coreutils?} do
    cond do
      not ready? ->
        IO.puts("\n[skip] SM eval-host not built"); :skip

      not coreutils? or "grep" not in CommandRegistry.list() ->
        IO.puts("\n[skip] coreutils/grep not available"); :skip

      true ->
        dir = workdir()
        agent = File.read!(@agent_js)

        # ONE session token carrying BOTH the exec/LLM grant AND the confined fs workdir.
        {:ok, pid} =
          HarnessSession.start_link(
            session_id: "agent-#{System.unique_integer([:positive])}",
            exec: [allow: true, principal: "agent-tenant"],
            fs: [workdir: dir, principal: "agent-tenant"]
          )

        assert HarnessSession.exec_token(pid) != nil

        # boot: install the Node platform (require/process/child_process/fs) + the resident agent, once.
        assert {:ok, boot} = HarnessSession.boot(pid, agent, env: %{"WB_MODEL" => "wb-mock-claude"})
        assert boot =~ "installed model=wb-mock-claude"

        # ── (a)+(c)+(d) the multi-step turn: fs-write -> fs-read -> llm -> brokered-exec -> llm -> fs-write ──
        t = drive_turn(pid, "Count how many lines match 'needle' in the repo, write a plan and the answer.")

        # (c) the LLM tool-loop produced the final answer; (d) state accumulated across the phases on one heap.
        assert t["answer"] == "The repository has 3 matching lines."
        assert t["phase"] == "stream"
        assert t["msgs"] >= 4
        assert t["toolCalls"] >= 1, "the brokered-exec tool ran"
        assert "PLAN.md" in t["files"] and "ANSWER.txt" in t["files"]
        assert t["log"] >= 4

        # (a) host-side fs confinement proof: the files are REAL, INSIDE the workdir, and nowhere else.
        assert File.read!(Path.join(dir, "ANSWER.txt")) == "The repository has 3 matching lines."
        assert File.read!(Path.join(dir, "PLAN.md")) =~ "# plan"

        # KEYSTONE: re-entry after the multi-step turn is now CLEAN — every host op went through the SYNCHRONOUS
        # host-import (no wasi:http future straddled the entry boundary), so the resident instance is NOT
        # poisoned. A plain compute eval re-enters fine with NO recycle.
        assert {:ok, "49"} = HarnessSession.eval(pid, "7*7")

        # PROVE a SECOND turn runs on the SAME resident instance with NO recycle — the conversation/scratchpad/
        # phase cursor from turn 1 are still live on the heap. Reset the agent's phase cursor for the new turn.
        assert {:ok, _} = HarnessSession.eval(pid, "globalThis.__agent.phase='plan';'ok'")
        t2 = drive_turn(pid, "again")
        assert t2["answer"] == "The repository has 3 matching lines."

        # recycle STILL works (the isolation/poison-recovery lever is intact even though the loop no longer
        # needs it) — a fresh heap under the same session id, then re-boot the resident agent.
        assert :ok = HarnessSession.recycle(pid)
        assert {:ok, "49"} = HarnessSession.eval(pid, "7*7")

        # ── (b) the STREAMING capstone: spawn a long-running CLI and CONSUME its INCREMENTAL stdout. The
        # streaming protocol now runs over the host-import (spawn/stream/stdin host-calls), so it too leaves the
        # instance re-enterable. Boot a fresh agent and fast-forward to the stream phase. ─────────────────────
        assert {:ok, _} = HarnessSession.boot(pid, agent, env: %{})
        assert {:ok, _} = HarnessSession.eval(pid, "globalThis.__agent.phase='stream';'ok'")
        cap = drive_stream(pid)

        assert cap["step"] == "stream"
        assert cap["done"] and cap["terminal"]
        assert cap["code"] == 0
        assert cap["lastLine"] == "200000"
        # streaming proof: output arrived across MORE THAN ONE 'data' event (not one buffered blob).
        assert cap["chunks"] > 1, "expected incremental streaming (chunks>1), got #{cap["chunks"]}"
        assert cap["bytes"] > 1_000_000

        # ── (a) confinement under a live token: a traversal escape is refused (no host-FS leak) — on the SAME
        # resident instance (re-entry is clean over the host-import; no recycle needed). ─────────────────────
        {:ok, denied} =
          HarnessSession.eval(
            pid,
            "(async()=>{try{await require('node:fs').promises.readFile('../../../../../../etc/passwd','utf8');return 'LEAK'}catch(e){return 'DENIED:'+e.code}})()"
          )

        assert denied =~ "DENIED:"
        refute denied =~ "LEAK"

        HarnessSession.stop(pid)
    end
  end
end
