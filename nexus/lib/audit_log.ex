defmodule Nexus.AuditLog do
  @moduledoc """
  The **immutable, hash-chained audit log** (wb-d8ac.23) — tamper-evident security history.

  Distinct from `Nexus.Audit` (the build-time capability-grant audit). This is the *runtime* ledger
  of security-relevant events: a grant issued, a role assigned, a dual-control approval, a member
  offboarded. Each entry carries the hash of the previous entry, so the whole org's log is a chain:
  altering or deleting any past entry breaks every hash after it, and `verify/1` detects exactly
  where. No regulated buyer signs without this; our owned, per-org store makes it straightforward.

      entry = %{seq, ts, actor, action, target, details, prev_hash}
      hash  = sha256( term_to_binary({seq, ts, actor, action, target, details, prev_hash}) )

  Appends are **serialized through a GenServer** so the chain can never fork under concurrency (two
  writers both reading the same tail and both appending seq N). Storage is the org-isolated
  control-plane store (kind `:audit`), so entries are durable and per-org — never cross-org.
  """
  use GenServer
  alias Nexus.ControlPlane, as: CP

  @genesis "GENESIS"

  # ── lifecycle ──────────────────────────────────────────────────────────────────────────────────

  def child_specs, do: [__MODULE__]
  def start_link(_ \\ []), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_), do: {:ok, %{}}

  # ── api ────────────────────────────────────────────────────────────────────────────────────────

  @doc """
  Append a security event to `org`'s chain. `event` carries `:actor`, `:action`, `:target`, and an
  optional `:details` map. Returns `{:ok, entry}` with the assigned `seq` and `hash`. Serialized.
  """
  @spec append(String.t(), map) :: {:ok, map}
  def append(org, event) when is_binary(org) and is_map(event) do
    GenServer.call(__MODULE__, {:append, org, event})
  end

  @doc "All entries in `org`'s log, in chain order (seq ascending)."
  @spec entries(String.t()) :: [map]
  def entries(org), do: CP.list(org, :audit) |> Enum.sort_by(& &1[:seq])

  @doc """
  Verify the integrity of `org`'s chain: recompute every hash from genesis. Returns `:ok`, or
  `{:error, {:tampered_at, seq}}` at the first entry whose stored hash or `prev_hash` link is wrong.
  """
  @spec verify(String.t()) :: :ok | {:error, {:tampered_at, integer}}
  def verify(org) do
    entries(org)
    |> Enum.reduce_while({:ok, @genesis}, fn e, {:ok, prev} ->
      expected = hash_of(e, prev)

      if e[:prev_hash] == prev and e[:hash] == expected do
        {:cont, {:ok, e[:hash]}}
      else
        {:halt, {:error, {:tampered_at, e[:seq]}}}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      err -> err
    end
  end

  # ── server ───────────────────────────────────────────────────────────────────────────────────────

  @impl true
  def handle_call({:append, org, event}, _from, state) do
    existing = entries(org)
    {seq, prev_hash} =
      case List.last(existing) do
        nil -> {1, @genesis}
        last -> {last[:seq] + 1, last[:hash]}
      end

    base = %{
      seq: seq,
      ts: System.os_time(:millisecond),
      actor: to_string(event[:actor] || "system"),
      action: to_string(event[:action] || ""),
      target: to_string(event[:target] || ""),
      details: event[:details] || %{},
      prev_hash: prev_hash
    }

    entry = Map.put(base, :hash, hash_of(base, prev_hash))
    {:ok, _} = CP.put(org, :audit, pad(seq), entry)
    {:reply, {:ok, entry}, state}
  end

  # ── hashing ──────────────────────────────────────────────────────────────────────────────────────

  # Deterministic, no JSON: term_to_binary over the canonical tuple (sorted-fixed field order).
  defp hash_of(e, prev_hash) do
    payload = :erlang.term_to_binary({e.seq, e.ts, e.actor, e.action, e.target, e.details, prev_hash})
    :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
  end

  # Zero-pad seq so the store's lexical id order matches numeric order (defensive; we sort by :seq too).
  defp pad(seq), do: seq |> Integer.to_string() |> String.pad_leading(12, "0")
end
