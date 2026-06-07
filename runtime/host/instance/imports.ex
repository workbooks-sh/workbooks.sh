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

  @doc "Build the Wasmex.Components imports map for an Instance, gated by Policy caps."
  def for_caps(caps, vfs_conn, info) do
    base = %{"session-info" => {:fn, fn -> Jason.encode!(info) end}}
    Enum.reduce(caps, base, &add(&1, &2, vfs_conn))
  end

  # vfs: run SQL against the Instance VFS, return rows as JSON.
  defp add("vfs", acc, vfs),
    do: Map.put(acc, "vfs-query", {:fn, fn sql -> VFS.query_json(vfs, sql) end})

  # commands: invoke a registered in-WASM command by name (argv + stdin → stdout).
  defp add("commands", acc, _vfs),
    do: Map.put(acc, "run-command", {:fn, fn name, input, args -> run_command(name, input, args) end})

  # llm: call the LLM (the host holds the key — the component never sees it).
  defp add("llm", acc, _vfs),
    do: Map.put(acc, "llm-complete", {:fn, fn prompt -> llm_complete(prompt) end})

  defp add(_other, acc, _), do: acc

  defp run_command(name, input, args) do
    case Workbooks.CommandRegistry.run(name, input, args) do
      {:ok, out} -> out
      {:error, e} -> Jason.encode!(%{error: inspect(e)})
    end
  end

  defp llm_complete(prompt) do
    case Workbooks.Llm.complete([%{role: "user", content: prompt}]) do
      {:ok, %{content: c}} -> c || ""
      {:error, e} -> "error: #{inspect(e)}"
    end
  end
end
