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

  # `exec` (host_exec / host_parallel_map) and `kv` (durable host_kv) are DEDICATED least-privilege caps,
  # distinct from the broad `commands` / `vfs` — so a profile can grant durable storage or networking WITHOUT
  # also granting the ability to spawn commands. The three standard profiles keep every capability; `compute`
  # is the restrictive demo (pure compute + ephemeral vfs only — no exec, no durable kv, no net).
  @profiles %{
    minimal: %{memory: 64 * 1024 * 1024, caps: ~w(vfs commands exec kv secrets queue tcp udp tls), timeout: 5_000},
    network: %{memory: 128 * 1024 * 1024, caps: ~w(vfs commands exec kv secrets queue tcp udp tls net llm browse), timeout: 30_000},
    posix: %{
      memory: 256 * 1024 * 1024,
      caps: ~w(vfs commands exec kv secrets queue tcp udp tls net llm browse posix parallel),
      timeout: 60_000
    },
    compute: %{memory: 64 * 1024 * 1024, caps: ~w(vfs), timeout: 5_000}
  }

  def profiles, do: Map.keys(@profiles)

  def store_limits(profile) do
    cap = profile |> fetch() |> Map.fetch!(:memory)
    %Wasmex.StoreLimits{memory_size: cap}
  end

  def caps(profile), do: profile |> fetch() |> Map.fetch!(:caps)

  @doc "Wall-clock CPU cap (ms) for one component call — the runaway trap."
  def timeout(profile), do: profile |> fetch() |> Map.fetch!(:timeout)

  @doc """
  Whether this profile may use host network (wasi:http + inherit_network +
  DNS). SECURITY (wb-sec, finding #7): derived from caps — ONLY profiles granting
  `net` or `browse` get network. `minimal` (caps: vfs, commands) gets NONE.

  In stock wasmex, `WasiP2Options.allow_http` is the single switch that gates
  BOTH `wasmtime_wasi_http::add_only_http_to_linker_sync` AND, in store.rs,
  `wasi_ctx_builder.inherit_network()` + `allow_ip_name_lookup`. So setting it
  false here means a non-network component cannot reach the host network stack at
  all (no http import linked, no socket pool inherited, no DNS) — closing the
  bypass where every Instance (even minimal) had full egress.
  """
  def allow_http?(profile) do
    caps = caps(profile)
    "net" in caps or "browse" in caps
  end

  defp fetch(profile), do: Map.get(@profiles, profile, @profiles.minimal)
end
