defmodule Nexus.Autopoet.Lease do
  @moduledoc """
  Scoped, auto-expiring capability LEASES (Autopoiesis v2 — wb-a6u3.5). When a request would cross an
  agent's ceiling, the autopoet doesn't durably widen the ceiling (that's the rare, human-gated act) —
  it issues a *lease*: a bounded, expiring grant of one capability to one principal. The agent gets
  unblocked for the task at hand; the ceiling never moves.

  Leases are **ephemeral runtime state** (a GenServer table, never a `.work` file — NO JSON), and
  **non-delegable by default**: a lease is keyed to its principal (the agent name), so a spawned
  sub-agent (a different principal) does not inherit it — it must request its own. Expiry is by TTL
  (`"15m"`, parsed via `Nexus.Time`); the cloud product revokes "until-issue-closes" leases explicitly.

  `Nexus.Agent.run_unit` unions a principal's active leases on top of its `declared ∩ ceiling` grant —
  the lease is the sanctioned, time-boxed way to exceed the normal ceiling.
  """

  use GenServer

  @doc false
  def start_link(_ \\ []), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  # Lazily start outside a supervision tree (tests, escript) without racing — mirrors Nexus.Telemetry.
  defp ensure do
    case Process.whereis(__MODULE__) do
      nil ->
        case start_link([]) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end

      _ ->
        :ok
    end
  end

  @doc """
  Grant `cap` to `principal` for a bounded time. Opts: `:ttl` (a duration like `"15m"`, default `"15m"`).
  Returns `{:ok, lease}` or `{:error, reason}`. Idempotent-ish: re-granting refreshes the expiry.
  """
  def grant(principal, cap, opts \\ []) do
    ensure()
    ttl = Keyword.get(opts, :ttl, "15m")

    case Nexus.Time.duration_ms(ttl) do
      {:ok, ms} ->
        lease = %{principal: to_string(principal), cap: to_string(cap), expires_at: now() + div(ms, 1000)}
        GenServer.call(__MODULE__, {:grant, lease})
        {:ok, lease}

      :error ->
        {:error, {:bad_ttl, ttl}}
    end
  end

  @doc "The capabilities currently leased to `principal` (expired leases excluded)."
  def active(principal) do
    ensure()
    GenServer.call(__MODULE__, {:active, to_string(principal)})
  end

  @doc "Revoke a specific leased cap from a principal."
  def revoke(principal, cap) do
    ensure()
    GenServer.call(__MODULE__, {:revoke, to_string(principal), to_string(cap)})
  end

  @doc "All non-expired leases (maintenance / inspection)."
  def all do
    ensure()
    GenServer.call(__MODULE__, :all)
  end

  @doc "Drop every lease (test/maintenance)."
  def clear do
    ensure()
    GenServer.call(__MODULE__, :clear)
  end

  # ── server ──

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:grant, lease}, _from, state) do
    key = {lease.principal, lease.cap}
    {:reply, :ok, Map.put(state, key, lease)}
  end

  def handle_call({:active, principal}, _from, state) do
    state = prune(state)

    caps =
      state
      |> Enum.filter(fn {{p, _c}, _l} -> p == principal end)
      |> Enum.map(fn {{_p, c}, _l} -> c end)

    {:reply, caps, state}
  end

  def handle_call({:revoke, principal, cap}, _from, state),
    do: {:reply, :ok, Map.delete(state, {principal, cap})}

  def handle_call(:all, _from, state) do
    state = prune(state)
    {:reply, Map.values(state), state}
  end

  def handle_call(:clear, _from, _state), do: {:reply, :ok, %{}}

  # Drop expired leases.
  defp prune(state), do: state |> Enum.filter(fn {_k, l} -> l.expires_at > now() end) |> Map.new()
  defp now, do: System.os_time(:second)
end
