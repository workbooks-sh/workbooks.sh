defmodule Nexus.F2 do
  @moduledoc """
  **The F2 (JS→BEAM) execution lane** — run confined JavaScript through `TinyLasers.Gate.Exec.invoke`, the
  warm-module / cold-process execution model: a program compiles ONCE and each request runs in a fresh,
  resource-bounded, preemptively-scheduled BEAM process, behind per-tenant admission + metering, with an
  atom-pressure recycle watchdog. The whole tier is supervised by the `:tiny_lasers` application, which boots as
  a dependency of nexus (see `TinyLasers.Application`) — so this module just routes requests to it.

  This is the *concurrency + isolation* lane, complementary to `Nexus.JsEngine` (StarlingMonkey). StarlingMonkey
  is a full ECMAScript + WHATWG engine on a single event loop; F2 covers the confined core-language workloads
  (compute, transforms, build/SSR) but wins where it matters for a multi-tenant server: a slow or runaway
  request runs in its own process and **cannot poison the others** (measured: a 16.8 ms handler at 5% of traffic
  drives node's fast-endpoint p99 to ~2.5 s; F2 stays sub-ms — see tiny-lasers `bench/concurrency`).
  """

  alias TinyLasers.Gate.Exec

  @exec_opts [:tenant, :max_rps, :max_inflight, :max_heap_size, :timeout, :granted, :caps, :cache]

  @doc "Run confined JS for a tenant. Returns the full `Exec.invoke` map (`%{result, output, admitted, …}`)."
  def run(js, opts \\ []) when is_binary(js), do: Exec.invoke(tenant(opts), js, Keyword.take(opts, @exec_opts))

  @doc "Run JS, returning `{:ok, output_lines} | {:rejected, reason} | {:error, term}`."
  def eval(js, opts \\ []) when is_binary(js) do
    case run(js, opts) do
      %{result: {:ok, _}, output: out} -> {:ok, out}
      %{result: {:rejected, reason}} -> {:rejected, reason}
      %{result: other} -> {:error, other}
    end
  end

  @doc "Is the F2 execution model up (supervised by the `:tiny_lasers` dependency)?"
  def available?, do: is_pid(Process.whereis(TinyLasers.Gate.ModuleCache))

  @doc "Node-health snapshot (atom pressure, in-flight, metering) for readiness probes."
  def health, do: Exec.health()

  @doc "Pre-compile a tenant's JS programs (deploy-time warm-up) so first requests are warm cache hits."
  def prewarm(tenant, sources, opts \\ []) when is_binary(tenant) and is_list(sources),
    do: Exec.prewarm(tenant, sources, opts)

  defp tenant(opts), do: opts[:tenant] || default_tenant()

  defp default_tenant do
    try do
      Nexus.Store.default_tenant()
    rescue
      _ -> "default"
    catch
      _, _ -> "default"
    end
  end
end
