defmodule Workbooks.Instance.Imports do
  @moduledoc """
  The Dock interface — host-side functions an Instance's component calls (the
  typed capability surface of the `workbooks:engine` world). Each entry is a
  plain Elixir closure with WIT-typed args; capability gating is by construction:
  the host provides only the imports the Policy grants, so a component importing
  a non-granted cap fails to instantiate.

  `session-info` is always granted (read-only ids). `vfs-query` runs SQL against
  the Instance's own SQLite VFS. `llm-complete`/`net-fetch` land with the
  network profile as their Policy caps are implemented.
  """
  alias Workbooks.VFS

  @doc """
  Build the Wasmex.Components imports map for an Instance, gated by Policy caps.

  `info` is the read-only id record the component sees via `session-info`.
  `opts[:workdir]` (host context, never exposed to the component) is the OS dir
  where the always-on telemetry log (`_steps.jsonl`) lives. When a workdir is
  present, every `run-command` Dock invocation appends one step
  (`tool: "command:<name>"`, exit_code, dur_ms, ts) there — the same shape
  `Workbooks.Agent.log_step` writes and `Workflow.Telemetry.summary/1` counts,
  so Dock command calls are observable exactly like agent tool calls.
  """
  def for_caps(caps, vfs_conn, info, opts \\ []) do
    base = %{"session-info" => {:fn, fn -> Jason.encode!(info) end}}
    ctx = %{workdir: opts[:workdir], step: :counters.new(1, [:atomics])}
    Enum.reduce(caps, base, &add(&1, &2, vfs_conn, ctx))
  end

  # vfs: run SQL against the Instance VFS, return rows as JSON.
  defp add("vfs", acc, vfs, _ctx),
    do: Map.put(acc, "vfs-query", {:fn, fn sql -> VFS.query_json(vfs, sql) end})

  # commands: invoke a registered in-WASM command by name (argv + stdin → stdout).
  defp add("commands", acc, _vfs, ctx),
    do: Map.put(acc, "run-command", {:fn, fn name, input, args -> run_command(name, input, args, ctx) end})

  # llm: call the LLM (the host holds the key — the component never sees it).
  defp add("llm", acc, _vfs, _ctx),
    do: Map.put(acc, "llm-complete", {:fn, fn prompt -> llm_complete(prompt) end})

  defp add(_other, acc, _, _ctx), do: acc

  defp run_command(name, input, args, ctx) do
    t0 = System.monotonic_time(:millisecond)

    {out, exit_code} =
      case Workbooks.CommandRegistry.run(name, input, args) do
        {:ok, out} -> {out, 0}
        {:error, e} -> {Jason.encode!(%{error: inspect(e)}), 1}
      end

    log_step(ctx, name, exit_code, System.monotonic_time(:millisecond) - t0)
    out
  end

  # Always-on per-call telemetry — appended lock-free to <workdir>/_steps.jsonl,
  # the same chokepoint shape the agent loop writes, so Dock command calls show
  # up in `Workflow.Telemetry.summary/1` (tool_calls, errors, timeline).
  defp log_step(%{workdir: wd, step: ctr}, name, exit_code, dur_ms) when is_binary(wd) do
    step = :counters.get(ctr, 1)
    :counters.add(ctr, 1, 1)

    line =
      Jason.encode!(%{
        step: step,
        tool: "command:#{name}",
        exit_code: exit_code,
        dur_ms: dur_ms,
        ts: System.system_time(:second)
      })

    File.write(Path.join(wd, "_steps.jsonl"), line <> "\n", [:append])
  rescue
    _ -> :ok
  end

  defp log_step(_ctx, _name, _exit_code, _dur_ms), do: :ok

  defp llm_complete(prompt) do
    case Workbooks.Llm.complete([%{role: "user", content: prompt}]) do
      {:ok, %{content: c}} -> c || ""
      {:error, e} -> "error: #{inspect(e)}"
    end
  end
end
