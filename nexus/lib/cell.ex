defmodule Nexus.Cell do
  @moduledoc """
  A **Cell** — one agent's wasm execution context as a single SUPERVISED BEAM process (wb-qgpz, the BEAM
  wasm kernel). Today a run wires up its `/work` dir, capability `grant`, tenant, an optional long-lived
  `Nexus.Wasmer.Session`, and an optional `Nexus.Membrane.Server` SEPARATELY, and tears them down by hand.
  A Cell bundles all of that into ONE lifecycle: start it, run command lines through it, stop it — and the
  session/socket/dir are owned, supervised, and cleaned up together.

  This is the kernel's unit: the BEAM supplies what wasm lacks (a scheduler, supervision, restart, a
  mailbox, tenancy) and the Cell is where that wraps a wasm execution. The *execution* still happens on
  wasmer (the shell) — the Cell is the BEAM-side envelope around it.

      {:ok, cell} = Cell.start(grant: ["fs", "exec"], stateful: true, bridge: true)
      Cell.run(cell, "mkdir -p /work/x && cd /work/x")   # state persists (session)
      Cell.run(cell, "cat /work/x/f | work parse")        # host caps compose (membrane bridge)
      Cell.stop(cell)                                      # session + socket + dir torn down

  Opts: `:dir` (host dir to mount at /work; a fresh temp dir if omitted), `:grant`, `:tenant`, `:caps`,
  `:stateful` (start a long-lived session — default false), `:bridge` (start a Membrane socket so host
  caps compose mid-pipe — default false), `:name` (Registry name).
  """
  use GenServer

  @registry Nexus.Cell.Registry
  @sup Nexus.Cell.Supervisor

  @doc "App-tree child specs: the cell Registry + the DynamicSupervisor cells run under."
  def child_specs do
    [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, name: @sup, strategy: :one_for_one}
    ]
  end

  @doc "Start a Cell under the supervisor. Returns `{:ok, pid}`."
  def start(opts \\ []) do
    DynamicSupervisor.start_child(@sup, {__MODULE__, opts})
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: via(opts[:name]))

  defp via(nil), do: nil
  defp via(name), do: {:via, Registry, {@registry, name}}

  @doc "Run a command line in the cell (its grant, session, and bridge apply). Returns combined stdout."
  def run(cell, line) when is_binary(line), do: GenServer.call(cell, {:run, line}, 130_000)

  @doc "The cell's perms map (grant + session + membrane), e.g. to hand to Nexus.Agent.Bash directly."
  def perms(cell), do: GenServer.call(cell, :perms)

  @doc "The cell's metering snapshot: %{runs, last_activity_ms, tenant}."
  def stats(cell), do: GenServer.call(cell, :stats)

  @doc "Stop the cell — tears down its session, socket, and (if owned) its /work dir."
  def stop(cell), do: GenServer.stop(cell, :normal)

  # ── GenServer ───────────────────────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    {vfs, owns_dir?} =
      case Keyword.get(opts, :dir) do
        nil -> {Nexus.Agent.Vfs.new(), true}
        dir -> {Nexus.Agent.Vfs.attach(dir), false}
      end

    base = %{
      grant: Keyword.get(opts, :grant),
      tenant: Keyword.get(opts, :tenant),
      caps: Keyword.get(opts, :caps, [])
    }

    # Optional long-lived shell (stateful cwd/env) — linked, so it dies with the cell.
    session =
      if Keyword.get(opts, :stateful, false) and Nexus.Wasmer.available?() do
        case Nexus.Wasmer.Session.start_link(Nexus.Agent.Vfs.dir(vfs)) do
          {:ok, s} -> s
          _ -> nil
        end
      end

    # Optional Membrane socket so host caps compose mid-pipe — bound to THIS cell's vfs + perms.
    membrane =
      if Keyword.get(opts, :bridge, false) do
        case Nexus.Membrane.Server.start_link(vfs, Map.put(base, :session, session)) do
          {:ok, srv} -> %{srv: srv, port: Nexus.Membrane.Server.port(srv), token: Nexus.Membrane.Server.token(srv)}
          _ -> nil
        end
      end

    perms =
      base
      |> maybe_put(:session, session)
      |> maybe_put(:membrane, membrane && Map.take(membrane, [:port, :token]))

    {:ok, %{vfs: vfs, owns_dir?: owns_dir?, perms: perms, session: session, membrane: membrane, runs: 0, last: 0}}
  end

  @impl true
  def handle_call({:run, line}, _from, state) do
    out = Nexus.Agent.Bash.run(state.vfs, line, state.perms)
    {:reply, out, %{state | runs: state.runs + 1, last: System.monotonic_time(:millisecond)}}
  end

  def handle_call(:perms, _from, state), do: {:reply, state.perms, state}

  def handle_call(:stats, _from, state),
    do: {:reply, %{runs: state.runs, last_activity_ms: state.last, tenant: state.perms[:tenant]}, state}

  @impl true
  def terminate(_reason, state) do
    if is_pid(state.session) and Process.alive?(state.session), do: Nexus.Wasmer.Session.stop(state.session)
    if state.membrane && Process.alive?(state.membrane.srv), do: Nexus.Membrane.Server.stop(state.membrane.srv)
    if state.owns_dir?, do: Nexus.Agent.Vfs.destroy(state.vfs)
    :ok
  end

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)
end
