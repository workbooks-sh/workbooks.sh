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
  # also granting the ability to spawn commands.
  #
  # Cap matrix (wb-8w8x audit — keep this in sync with the table):
  #   * compute — `vfs` ONLY (pure compute + ephemeral vfs; no exec, no durable kv, no secrets, no net).
  #     This is the FAIL-CLOSED default for an unknown/typo'd profile (see fetch/1).
  #   * minimal — every LOCAL cap (vfs, commands, exec, kv, secrets, queue) + the SSRF-brokered raw sockets
  #     (tcp, udp, tls), but NO high-level net egress (net/llm/browse). "minimal network", not "minimal caps":
  #     a caller selecting it still authorizes signing + raw-socket egress, so pick `compute` for true sandbox.
  #   * network — minimal + net/llm/browse (host HTTP egress + LLM).
  #   * posix — network + posix + parallel (the full surface).
  # `encode` (host_ffmpeg_encode) is a DEDICATED least-privilege cap for the host ffmpeg ENCODE broker (the
  # one bedrock escape — native ffmpeg the guest cannot run in-wasm). Granted to the local-cap profiles
  # (minimal+); a true sandbox (`compute`) gets vfs only and cannot encode.
  @profiles %{
    minimal: %{memory: 64 * 1024 * 1024, caps: ~w(vfs commands exec kv secrets queue tcp udp tls encode), timeout: 5_000},
    network: %{memory: 128 * 1024 * 1024, caps: ~w(vfs commands exec kv secrets queue tcp udp tls net llm browse encode), timeout: 30_000},
    posix: %{
      memory: 256 * 1024 * 1024,
      caps: ~w(vfs commands exec kv secrets queue tcp udp tls net llm browse posix parallel encode),
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
  Whether this profile may use host HIGH-LEVEL network (wasi:http + inherit_network
  + DNS). SECURITY (wb-sec, finding #7): derived from caps — ONLY profiles granting
  `net` or `browse` get it. `minimal` gets NONE (note: minimal still grants the
  SSRF-brokered raw-socket caps tcp/udp/tls; this switch is the wasi:http/DNS gate).

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

  # wb-8w8x: an UNKNOWN/typo'd profile FAILS CLOSED to `compute` (vfs-only) — NOT the over-granting `minimal`.
  # A misspelled profile must yield LEAST privilege, never silently authorize secrets/exec/kv/raw-sockets.
  defp fetch(profile), do: Map.get(@profiles, profile, @profiles.compute)
end
