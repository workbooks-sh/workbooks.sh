defmodule Workbooks.Policy do
  @moduledoc """
  Workbook Policy — the rules an Instance must obey. A profile maps to a memory
  cap (validated: a component growing past it traps) and a capability set (which
  Dock imports of the `workbooks:engine` world it may call). Both use stock
  Wasmex; no fork.

  CPU cap: a per-profile wall-clock `timeout` (ms). Component calls run on a
  tokio thread (not a BEAM scheduler), so a call that overruns its budget is
  trapped at the boundary — the caller gets `{:error, :cpu_timeout}` and the BEAM
  stays responsive. Stock Wasmex (`Wasmex.Components.call_function/4` takes the
  timeout); no fork. Epoch interruption (wb-11ck.11/.13) is a later refinement
  that also frees the runaway worker thread; the wall-clock cap is the trap.
  """

  @profiles %{
    minimal: %{memory: 64 * 1024 * 1024, caps: ~w(vfs commands), timeout: 5_000},
    network: %{memory: 128 * 1024 * 1024, caps: ~w(vfs commands net llm browse), timeout: 30_000},
    posix: %{memory: 256 * 1024 * 1024, caps: ~w(vfs commands net llm browse posix), timeout: 60_000}
  }

  def profiles, do: Map.keys(@profiles)

  def store_limits(profile) do
    cap = profile |> fetch() |> Map.fetch!(:memory)
    %Wasmex.StoreLimits{memory_size: cap}
  end

  def caps(profile), do: profile |> fetch() |> Map.fetch!(:caps)

  @doc "Wall-clock CPU cap (ms) for one component call — the runaway trap."
  def timeout(profile), do: profile |> fetch() |> Map.fetch!(:timeout)

  defp fetch(profile), do: Map.get(@profiles, profile, @profiles.minimal)
end
