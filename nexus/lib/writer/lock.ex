defmodule Nexus.Writer.Lock do
  @moduledoc """
  Single-writer guard. The durability model assumes ONE machine = one SQLite writer = one Litestream
  replicating to the bucket. Two machines would mean split-brain SQLite (Fly volumes are per-machine)
  AND two Litestreams replicating the same object path — corruption, an amplified empty-generation
  cascade. Nothing in Fly stops `min_machines_running>1` or a stray second machine, so we enforce it.

  The gate runs in the **entrypoint, BEFORE `litestream replicate`** (`acquire/0` via `bin/nexus eval`):
  Litestream is the parent process, so once it's replicating an app-level halt is too late. `acquire/0`
  reads a **lease object** next to the DB replica (`litestream/writer.lease`); a FRESH lease from another
  machine ⇒ `false` (the entrypoint refuses to boot). A crashed writer's lease expires after `@ttl`, so
  the survivor takes over. Once running, the `Nexus.Writer.Lock` GenServer heartbeats the lease.

  Fail-OPEN: an unreachable object store ⇒ proceed (never block the legitimate single writer); the lease
  only ever PREVENTS an accidental second writer.
  """
  use GenServer
  require Logger

  @key "writer.lease"
  @ttl 90

  @doc "Entrypoint gate (one-shot, run via `bin/nexus eval` before litestream). `true` = safe to start."
  def acquire do
    cond do
      not active?() ->
        true

      conflicting_lease?() ->
        Logger.error("[writer-lock] another machine holds a fresh writer lease — refusing to start a second writer")
        false

      true ->
        write_lease(machine_id())
        true
    end
  end

  # ── heartbeat GenServer (keeps our lease fresh while we run) ──────────────────────────────────────
  def child_specs, do: if(active?(), do: [__MODULE__], else: [])
  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    write_lease(machine_id())
    :timer.send_interval(div(@ttl, 3) * 1000, :heartbeat)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:heartbeat, st) do
    write_lease(machine_id())
    {:noreply, st}
  end

  # ── lease I/O ─────────────────────────────────────────────────────────────────────────────────────
  defp active?, do: Nexus.Litestream.enabled?() and Nexus.S3.configured?() and lease_loc() != nil

  defp conflicting_lease? do
    case read_lease() do
      {:ok, %{"machine" => other, "ts" => ts}} when is_binary(other) -> other != machine_id() and fresh?(ts)
      _ -> false
    end
  end

  defp read_lease do
    case Nexus.S3.get(lease_loc(), @key) do
      {:ok, body} -> Jason.decode(body)
      _ -> :miss
    end
  end

  defp write_lease(me) do
    Nexus.S3.put(lease_loc(), @key, Jason.encode!(%{machine: me, ts: now()}))
  rescue
    _ -> :ok
  end

  defp fresh?(ts) when is_integer(ts), do: now() - ts < @ttl
  defp fresh?(_), do: false
  defp now, do: System.os_time(:second)
  defp machine_id, do: System.get_env("FLY_MACHINE_ID") || System.get_env("FLY_ALLOC_ID") || "single"

  defp lease_loc do
    case Nexus.Litestream.replica() do
      %{bucket: b, endpoint: e, region: r} -> %{bucket: b, endpoint: e, region: r, prefix: "litestream"}
      _ -> nil
    end
  end
end
