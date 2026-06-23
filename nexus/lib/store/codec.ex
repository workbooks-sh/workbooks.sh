defmodule Nexus.Store.Codec do
  @moduledoc """
  The ONE seam that turns a stored/restored byte blob back into a term — and the only place in the
  runtime allowed to deserialize a persisted blob.

  ## Why this exists

  Every durable row, token record, and control-plane record round-trips through `term_to_binary` on
  write and a decode on read. The naive decode is `:erlang.binary_to_term/1`, which is a documented
  RCE / atom-exhaustion primitive the moment an attacker can influence the bytes — and the bytes live
  in a SQLite file that **Litestream restores from R2 on machine churn**, so the blob source is not
  fully trusted (a poisoned replica, a shared bucket, a future raw-write path all reach this decode).
  See the red-team chain wb-w0el → wb-h437 / wb-m73h.

  This module closes that boundary two ways:

  1. **Safe sink** — `decode/1` uses `Plug.Crypto.non_executable_binary_to_term(blob, [:safe])`, which
     refuses to build anonymous-function / external-fun / port / pid gadgets and bounds atom creation.
     A persisted struct (enum atoms, scalars, maps, lists) round-trips exactly; an executable gadget
     raises instead of detonating.
  2. **Quarantine, not crash** — a malformed or hostile blob raises inside `decode/1`; the row-level
     readers (`decode_row*`) rescue it, drop the single poisoned row, and emit a telemetry/log marker
     instead of taking down the whole `all/page` call (and with it the tenant's entire table).

  `encode/1` is the matching write side so the pair lives in one place.
  """

  require Logger

  @doc "Serialize a term for durable storage. The write half of the codec pair."
  @spec encode(term()) :: binary()
  def encode(term), do: :erlang.term_to_binary(term)

  @doc """
  Decode a single stored blob via the non-executable, atom-bounded safe sink.

  Raises `ArgumentError` on a hostile/malformed blob — callers that read a *set* of rows should use
  `decode_rows/2` so one poisoned row is quarantined rather than failing the whole read.
  """
  @spec decode(binary()) :: term()
  def decode(blob) when is_binary(blob) do
    Plug.Crypto.non_executable_binary_to_term(blob, [:safe])
  end

  @doc """
  Decode a list of `[blob]`-shaped SQLite rows, quarantining any row whose blob fails the safe decode.

  Returns only the rows that decoded cleanly. A dropped row is logged with `context` so a poisoned
  replica surfaces in telemetry instead of silently vanishing or crashing the table read.
  """
  @spec decode_rows([[binary()]], keyword()) :: [term()]
  def decode_rows(rows, context \\ []) do
    rows
    |> Enum.flat_map(fn [blob] ->
      case safe(blob, context) do
        {:ok, term} -> [term]
        :quarantined -> []
      end
    end)
  end

  # Single-blob safe decode used by token/control-plane stores that hold one record per row.
  @doc false
  @spec decode_one(binary(), keyword()) :: {:ok, term()} | :quarantined
  def decode_one(blob, context \\ []), do: safe(blob, context)

  defp safe(blob, context) do
    {:ok, decode(blob)}
  rescue
    e ->
      :telemetry.execute([:nexus, :store, :codec, :quarantine], %{count: 1}, %{
        context: context,
        error: Exception.message(e)
      })

      Logger.error(
        "Nexus.Store.Codec quarantined a poisoned blob (#{inspect(context)}): #{Exception.message(e)}"
      )

      :quarantined
  end
end
