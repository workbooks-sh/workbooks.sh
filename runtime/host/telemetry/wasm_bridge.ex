defmodule Workbooks.Telemetry.WasmBridge do
  @moduledoc """
  The WASM-path telemetry bridge — the inner boundary's observability point.

  Native tool calls (the BEAM `run`/`shell`/`fetch` tools) are already captured
  at the chokepoint in `Workbooks.Agent` → `_steps.jsonl`. But work that runs
  *inside* a WASM component is opaque to that — its spans live behind the Dock.
  This bridge closes the gap: it provides the host side of an Observe-style
  `instrument-enter` / `instrument-exit` import pair (the same shape the WASI
  observability proposal and the Dylibso Observe SDK both surface), and writes
  each completed span into the SAME `_steps.jsonl` ledger, in the SAME event
  shape the native path uses.

  That sameness is the whole point: `Workbooks.Workflow.Telemetry.summary/1` and
  `index/2` already read `_steps.jsonl`, so a span emitted from inside a component
  shows up in the per-run summary and the cross-session index with ZERO new query
  code. One ledger, whether the tool ran on the BEAM or inside the sandbox.

  ADOPT, don't author: the guest emits these calls via the Dylibso Observe SDK's
  wasm-to-wasm transform (mature, language-agnostic) or the wasi:otel proposal
  once it + Wasmtime/Wasmex stabilize. This module is only the host sink — see
  docs/WASI-OTEL-SPIKE.org. Wiring it into a real component is blocked on that
  guest-side transform tooling (honest TODO there); the bridge itself is complete
  and unit-tested in isolation.
  """
  @table :wasm_span_stack

  @doc """
  The `{:fn, closure}` import map to merge into `Workbooks.Instance.Imports`
  (gated behind a `telemetry` cap). Closures capture the Instance's `workdir` so
  spans land in that run's ledger.
  """
  def imports(workdir) do
    %{
      "instrument-enter" => {:fn, fn name -> enter(workdir, name); "" end},
      "instrument-exit" => {:fn, fn name -> exit_span(workdir, name); "" end}
    }
  end

  @doc "Open a span: push its start time onto this workdir's stack."
  def enter(workdir, name) do
    ensure_table()
    :ets.insert(@table, {{workdir, key(name)}, mono()})
    :ok
  end

  @doc """
  Close a span: pop its start, compute duration, append it to `_steps.jsonl` in
  the native event shape so the existing summary/index pick it up unchanged.
  """
  def exit_span(workdir, name) do
    ensure_table()
    k = {workdir, key(name)}

    dur =
      case :ets.take(@table, k) do
        [{^k, t0}] -> mono() - t0
        _ -> 0
      end

    ev = %{step: nil, tool: "wasm:#{name}", exit_code: 0, error: nil, dur_ms: dur, ts: System.system_time(:second)}
    append(workdir, ev)
    :ok
  end

  defp append(workdir, ev) when is_binary(workdir) do
    File.write(Path.join(workdir, "_steps.jsonl"), Jason.encode!(ev) <> "\n", [:append])
  rescue
    _ -> :ok
  end

  defp append(_, _), do: :ok

  defp key(name), do: name
  defp mono, do: System.monotonic_time(:millisecond)

  # Lazy public ETS table — span timing is shared across the enter/exit host
  # calls (separate component→host crossings) so it can't live in a closure.
  # owned by the long-lived Workbooks.BrokerTables process (wb self-audit: a transient caller that creates a
  # named table takes it down on exit, losing span state).
  defp ensure_table, do: Workbooks.BrokerTables.ensure(@table, [:named_table, :public, :set])
end
