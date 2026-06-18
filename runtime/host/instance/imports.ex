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

  # The import NAME each capability projects comes from the single `Workbooks.Dock`
  # registry (§3) — so this seam and §2's generated worlds share one source of truth.
  # The impls stay here; `put/3` looks the name up. A characterization snapshot +
  # registry↔seam cross-check (dock_test, instance_imports_characterization_test) lock
  # this to the prior hardcoded names.

  # vfs: run SQL against the Instance VFS, return rows as JSON.
  defp add("vfs", acc, vfs, _ctx),
    do: put(acc, "vfs", fn sql -> VFS.query_json(vfs, sql) end)

  # commands: invoke a registered in-WASM command by name (argv + stdin → stdout).
  defp add("commands", acc, _vfs, ctx),
    do: put(acc, "commands", fn name, input, args -> run_command(name, input, args, ctx) end)

  # llm: call the LLM (the host holds the key — the component never sees it).
  defp add("llm", acc, _vfs, _ctx),
    do: put(acc, "llm", fn prompt -> llm_complete(prompt) end)

  # browse: fetch+extract a URL through the host's Browse capability (Route B —
  # the host owns network egress; the component never opens a socket). The
  # extracted page is normalized to a JSON string for the typed `-> string` Dock.
  defp add("browse", acc, _vfs, _ctx),
    do: put(acc, "browse", fn url -> browse_fetch(url) end)

  # parallel: fan a registered command over N inputs across isolated instances
  # (the distributed-compute primitive, Workbooks.Fabric). The component passes a
  # JSON array of stdin strings; the host runs them concurrently (BEAM does the
  # parallelism a single-threaded wasm instance can't) and returns a JSON array of
  # {"ok": stdout} | {"error": reason}, in order. This is how an intensive toolkit
  # borrows BEAM distribution; the media/render fabric is one consumer.
  defp add("parallel", acc, _vfs, _ctx),
    do: put(acc, "parallel", fn name, inputs_json -> run_command_many(name, inputs_json) end)

  defp add(_other, acc, _, _ctx), do: acc

  # project a capability's impl under the import name the Dock registry assigns it
  defp put(acc, cap, fun), do: Map.put(acc, Workbooks.Dock.import_name(cap), {:fn, fun})

  defp run_command(name, input, args, ctx) do
    t0 = System.monotonic_time(:millisecond)

    # Trust-aware run (wb-pkh.5): a third-party command runs at :node (a separate
    # BEAM VM); first-party runs locally. run_isolated falls back to local if
    # distribution can't start, so the command always runs.
    {out, exit_code} =
      case Workbooks.CommandRegistry.run_isolated(name, input, args) do
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

  # Reach the host Browse capability and hand the component a JSON string. The
  # component sees only the typed `-> string` result; it never touches the socket.
  defp browse_fetch(url) do
    case Workbooks.Browse.fetch(url) do
      {:ok, page} -> Jason.encode!(page)
      {:error, e} -> Jason.encode!(%{error: inspect(e)})
    end
  rescue
    e -> Jason.encode!(%{error: inspect(e)})
  end

  # Fan a command over a JSON array of stdin strings via the Fabric, marshal the
  # ordered results back as a JSON array. The component never manages concurrency
  # itself — it hands the host the work and gets the results.
  defp run_command_many(name, inputs_json) do
    case Jason.decode(inputs_json) do
      {:ok, inputs} when is_list(inputs) ->
        {:ok, results} = Workbooks.Fabric.map(name, Enum.map(inputs, &to_string/1))

        Jason.encode!(
          Enum.map(results, fn
            {:ok, out} -> %{"ok" => out}
            {:error, reason} -> %{"error" => inspect(reason)}
          end)
        )

      _ ->
        Jason.encode!(%{"error" => "run-command-many: inputs must be a JSON array of strings"})
    end
  rescue
    e -> Jason.encode!(%{"error" => inspect(e)})
  end

  defp llm_complete(prompt) do
    case Workbooks.Llm.complete([%{role: "user", content: prompt}]) do
      {:ok, %{content: c}} -> c || ""
      {:error, e} -> "error: #{inspect(e)}"
    end
  end
end
