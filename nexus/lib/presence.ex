defmodule Nexus.Presence do
  @moduledoc """
  **Ephemeral presence + typing** — the real-time side-channel, deliberately kept OUT of the durable
  store (open standard, generic mechanism only).

  Presence ("who is here", "who is typing") is high-frequency, disposable chatter: it changes every
  few seconds, is worthless after a heartbeat or two, and must never compete with the system-of-record
  for a write lock. So it lives in **its own in-memory store** (an ETS table owned by this GenServer),
  separate from `Nexus.Store` / the per-workspace SQLite DB. A presence row is just `{tenant, channel,
  user} → {state, last_seen}`; nothing here is ever persisted, shipped by Litestream, or written to
  `.work`. Crash or restart and presence simply re-populates from the next heartbeat.

  TTL-swept: a client `touch/4`es its presence on a heartbeat (~every 15s); a row older than
  `@ttl_ms` is considered gone and pruned, so a client that drops off the network silently expires
  without an explicit leave. `here/2` only ever returns live rows.

  Changes fan out to live subscribers (`subscribe/2` → `{:presence, snapshot}` messages), the same
  shape the websocket layer streams to browsers — so presence is live without polling, and without
  ever touching the durable layer.
  """
  use GenServer

  @table :nexus_presence
  @reg Nexus.Presence.Registry
  @ttl_ms 30_000
  @sweep_ms 10_000

  # ── lifecycle ──────────────────────────────────────────────────────────────────────────────────

  @doc "Child specs — a subscriber Registry + this GenServer (which owns the ephemeral ETS table)."
  def child_specs, do: [{Registry, keys: :duplicate, name: @reg}, __MODULE__]

  def start_link(_ \\ []), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  # ── api ────────────────────────────────────────────────────────────────────────────────────────

  @doc """
  Mark `user` present in `channel` (within `tenant`), with an optional `state` (`:online` default,
  or `:typing`). Refreshes the TTL. Call on connect and on every heartbeat. Broadcasts the new
  channel snapshot to subscribers.
  """
  @spec touch(String.t(), String.t(), String.t(), atom) :: :ok
  def touch(tenant, channel, user, state \\ :online)
      when is_binary(tenant) and is_binary(channel) and is_binary(user) and is_atom(state) do
    :ets.insert(@table, {{tenant, channel, user}, state, now_ms()})
    broadcast(tenant, channel)
    :ok
  end

  @doc "Set/clear `user`'s typing flag in `channel`. Sugar over `touch/4` with `:typing`/`:online`."
  @spec typing(String.t(), String.t(), String.t(), boolean) :: :ok
  def typing(tenant, channel, user, on?) when is_boolean(on?) do
    touch(tenant, channel, user, if(on?, do: :typing, else: :online))
  end

  @doc "Explicitly drop `user` from `channel` (e.g. on a clean disconnect). Broadcasts the snapshot."
  @spec leave(String.t(), String.t(), String.t()) :: :ok
  def leave(tenant, channel, user) do
    :ets.delete(@table, {tenant, channel, user})
    broadcast(tenant, channel)
    :ok
  end

  @doc """
  Who is live in `channel` right now — `[%{user:, state:, last_seen:}]`, freshest first, excluding
  rows past their TTL. Pure read; never mutates (the sweep prunes).
  """
  @spec here(String.t(), String.t()) :: [map]
  def here(tenant, channel) do
    cutoff = now_ms() - @ttl_ms

    @table
    |> :ets.match_object({{tenant, channel, :_}, :_, :_})
    |> Enum.filter(fn {_k, _state, seen} -> seen >= cutoff end)
    |> Enum.map(fn {{_t, _c, user}, state, seen} -> %{user: user, state: state, last_seen: seen} end)
    |> Enum.sort_by(& &1.last_seen, :desc)
  end

  @doc "Subscribe the caller to presence changes for `channel`; delivers `{:presence, here_snapshot}`."
  @spec subscribe(String.t(), String.t()) :: :ok
  def subscribe(tenant, channel) do
    {:ok, _} = Registry.register(@reg, {tenant, channel}, nil)
    :ok
  end

  # ── internals ────────────────────────────────────────────────────────────────────────────────────

  defp broadcast(tenant, channel) do
    snap = here(tenant, channel)

    Registry.dispatch(@reg, {tenant, channel}, fn entries ->
      for {pid, _} <- entries, do: send(pid, {:presence, snap})
    end)
  rescue
    _ -> :ok
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = now_ms() - @ttl_ms
    # Drop every row whose last_seen is past the TTL. select_delete with a guard on the 3rd element.
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_ms)
  defp now_ms, do: System.system_time(:millisecond)
end
