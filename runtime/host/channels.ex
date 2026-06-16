defmodule Workbooks.Channels do
  @moduledoc """
  Messaging-channel registry + dispatch (official-API tier, OpenClaw-style).

  A channel is a runtime CAPABILITY module, not an agent tool: credentials live
  runtime-side (env / WB_DATA), never in workbook or sandbox content. A channel
  is "configured" iff its adapter finds its credential (`configured?/0`); only
  configured channels accept sends, and only their inbound pollers are started
  (gated in `Workbooks.Application`, the keeper pattern).

  ## DM policy — pairing-code allowlist

  Unknown senders never reach the inbox: the adapter replies with a short
  pairing code and parks them. `approve/2` (control plane / `work channels
  approve`) moves them onto the allowlist. State is two small JSON/JSONL files
  under `<WB_DATA>/channels/`:

      allow-<channel>.json      {"approved": [peer], "pending": {code: peer}}
      <channel>-inbox.jsonl     one inbound message per line
  """

  @adapters %{"telegram" => Workbooks.Channels.Telegram}

  @doc "All known channels with their configured flag."
  def list do
    Enum.map(@adapters, fn {name, mod} -> %{channel: name, configured: mod.configured?()} end)
  end

  @doc "Send `text` to `peer` over `channel` via its adapter. Routes only when configured."
  def send(channel, peer, text, opts \\ []) do
    case Map.get(@adapters, channel) do
      nil -> {:error, :unknown_channel}
      mod -> if mod.configured?(), do: mod.send_message(peer, text, opts), else: {:error, :not_configured}
    end
  end

  # ── DM policy ───────────────────────────────────────────────────────────────

  @doc """
  Classify an inbound sender: `:allowed` (on the allowlist) or `{:pairing, code}`
  (unknown — the adapter replies with the code). Idempotent: an already-pending
  peer keeps its existing code instead of minting a new one per message.
  """
  def check_sender(channel, peer) do
    state = read(channel)

    cond do
      peer in state["approved"] ->
        :allowed

      code = Enum.find_value(state["pending"], fn {c, p} -> p == peer && c end) ->
        {:pairing, code}

      true ->
        code = :crypto.strong_rand_bytes(4) |> Base.encode32(padding: false) |> binary_part(0, 6)
        write(channel, put_in(state, ["pending", code], peer))
        {:pairing, code}
    end
  end

  @doc "Approve a pairing code: move its peer onto the allowlist. {:ok, peer} | :not_found."
  def approve(channel, code) do
    state = read(channel)

    case state["pending"][code] do
      nil ->
        :not_found

      peer ->
        write(channel, %{state | "approved" => Enum.uniq([peer | state["approved"]]), "pending" => Map.delete(state["pending"], code)})
        {:ok, peer}
    end
  end

  @doc "Persist an inbound message to the channel's JSONL inbox (this slice's terminus)."
  def inbox_append(channel, record) do
    File.mkdir_p!(dir())
    File.write!(Path.join(dir(), "#{channel}-inbox.jsonl"), Jason.encode!(record) <> "\n", [:append])
    :ok
  end

  @doc "Channel state root: <WB_DATA>/channels (tmp/data in dev, the volume when deployed)."
  def dir, do: Path.join(System.get_env("WB_DATA", "tmp/data"), "channels")

  defp read(channel) do
    case File.read(Path.join(dir(), "allow-#{channel}.json")) do
      {:ok, body} -> Jason.decode!(body)
      _ -> %{"approved" => [], "pending" => %{}}
    end
  end

  defp write(channel, state) do
    File.mkdir_p!(dir())
    File.write!(Path.join(dir(), "allow-#{channel}.json"), Jason.encode!(state))
  end
end
