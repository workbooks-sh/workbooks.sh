defmodule Workbooks.Instance do
  @moduledoc """
  One running Workbook Instance — a single Wasmtime component under one
  GenServer, memory-capped by its Policy, calling the typed Dock imports
  (`workbooks:engine`) its caps grant. A Workbook is a Component; the Instance
  is the engine it docks into. A fault (trap, OOM) returns an error tuple; the
  supervisor decides. The BEAM survives. (VALIDATION.org)

  Memory is capped via StoreLimits (validated: a component growing past it
  traps). CPU capping for components is the open epoch-interruption work
  (wb-11ck.11/.13) — Wasmex 0.14 surfaces fuel only on core-module stores, not
  component stores, so an Instance carries no CPU cap yet. Core-module tools
  (Javy output) run fuel-capped through the Package Manager, not as Instances.
  """
  use GenServer
  alias Workbooks.Policy

  def start_link({id, wasm_bytes, opts}),
    do: GenServer.start_link(__MODULE__, {id, wasm_bytes, opts}, name: via(id))

  @doc "Call an exported function on this Instance's component (the inner CPU cap bounds it)."
  def call(id, fun, args), do: GenServer.call(via(id), {:call, fun, args}, :infinity)

  @doc "Read/write this Instance's own VFS, in a named volume (default workspace)."
  def vfs_put(id, path, content, volume \\ "workspace"),
    do: GenServer.call(via(id), {:vfs_put, path, content, volume})

  def vfs_get(id, path, volume \\ "workspace"),
    do: GenServer.call(via(id), {:vfs_get, path, volume})

  def info(id), do: GenServer.call(via(id), :info)

  defp via(id), do: {:via, Registry, {Workbooks.Instance.Registry, id}}

  @impl true
  def init({id, bytes, opts}) do
    profile = Keyword.get(opts, :policy, :minimal)
    # Each Instance owns a VFS (its state). ":memory:" gives an isolated store.
    {:ok, vfs} = Workbooks.VFS.open(Keyword.get(opts, :vfs, ":memory:"))
    # session/info — the read-only ids the component sees via `session-info`.
    sess = %{id: id, tenant: Keyword.get(opts, :tenant), profile: profile}
    # workdir (when given) scopes the always-on Dock telemetry log. It is host
    # context only — NOT folded into `sess`, so `session-info` never leaks the
    # host path to the component.
    imports =
      Workbooks.Instance.Imports.for_caps(Policy.caps(profile), vfs, sess,
        workdir: Keyword.get(opts, :workdir)
      )
    # A WASI context links the wasi:* interfaces a component needs to *instantiate*
    # — JS components (StarlingMonkey) hard-link wasi:http/io even when unused.
    # stdio is not inherited (sandboxed); the typed Dock is the real surface.
    #
    # SECURITY (wb-sec, finding #7): allow_http is DERIVED from the profile, not
    # hardcoded true. In stock wasmex this single flag gates wasi:http linking AND
    # inherit_network()+DNS in store.rs — so a non-network profile (minimal) gets
    # NO host network at all (no http import, no socket pool, no name lookup). The
    # network egress bypass (every Instance reaching wasi:http regardless of caps)
    # is closed: only `net`/`browse` profiles get egress.
    allow_http = Policy.allow_http?(profile)

    {:ok, pid} =
      Wasmex.Components.start_link(%{
        bytes: bytes,
        store_limits: Policy.store_limits(profile),
        wasi: %Wasmex.Wasi.WasiP2Options{
          inherit_stdin: false,
          inherit_stdout: false,
          inherit_stderr: false,
          allow_http: allow_http
        },
        imports: imports
      })

    timeout = Keyword.get(opts, :timeout, Policy.timeout(profile))
    {:ok, %{id: id, pid: pid, vfs: vfs, profile: profile, timeout: timeout, calls: 0}}
  end

  @impl true
  def handle_call({:call, fun, args}, _from, s) do
    {:reply, capped(s, fun, args), %{s | calls: s.calls + 1}}
  end

  def handle_call({:vfs_put, p, c, v}, _from, s), do: {:reply, Workbooks.VFS.put(s.vfs, p, c, v), s}
  def handle_call({:vfs_get, p, v}, _from, s), do: {:reply, Workbooks.VFS.get(s.vfs, p, v), s}

  def handle_call(:info, _from, s),
    do: {:reply, %{id: s.id, profile: s.profile, caps: Policy.caps(s.profile), calls: s.calls}, s}

  # CPU cap: a component call runs on a tokio thread; if it overruns its profile
  # budget the boundary call times out, we catch it, and the caller gets a clean
  # {:error, :cpu_timeout} — the BEAM never wedges. (The runaway worker is freed
  # by epoch interruption, wb-11ck.11/.13; the wall-clock cap is the trap.)
  defp capped(s, fun, args) do
    Wasmex.Components.call_function(s.pid, fun, args, s.timeout)
  catch
    :exit, {:timeout, _} -> {:error, :cpu_timeout}
  end
end
