defmodule Workbooks.Channels.Telegram do
  @moduledoc """
  Telegram channel adapter — the official Bot API, nothing reverse-engineered.

  Outbound: `send_message/3` → `sendMessage` (text; optional `:parse_mode`).
  Inbound: this module is ALSO a supervised long-poll GenServer (`getUpdates`,
  25s holds) started by `Workbooks.Application` only when the token is present.
  Each inbound message runs the DM policy (`Workbooks.Channels.check_sender/2`):
  allowed senders land in the JSONL inbox; unknown senders get a pairing-code
  reply. Agent-session routing is deliberately NOT wired in this slice.

  The token comes from `TELEGRAM_BOT_TOKEN` — runtime env, never workbook
  content. HTTP is built-in `:httpc` (the Llm/DataSource.Http idiom), injectable
  via `opts[:http]` so tests run without network.
  """
  use GenServer
  require Logger

  @api "https://api.telegram.org"

  # ── adapter surface (Workbooks.Channels contract) ───────────────────────────

  @doc "Configured iff TELEGRAM_BOT_TOKEN is set."
  def configured?, do: token() not in [nil, ""]

  def token, do: System.get_env("TELEGRAM_BOT_TOKEN")

  @doc "Send a text message to a chat. opts: :parse_mode, :http (test stub), :token."
  def send_message(peer, text, opts \\ []) do
    post = opts[:http] || (&post_json/2)

    case post.(url("sendMessage", opts[:token] || token()), Jason.encode!(payload(peer, text, opts))) do
      {:ok, %{"ok" => true}} -> {:ok, %{channel: "telegram", peer: peer}}
      {:ok, other} -> {:error, {:telegram, other["description"] || inspect(other)}}
      {:error, _} = err -> err
    end
  end

  @doc "Bot API method URL (the token is path material — keep it out of logs)."
  def url(method, token), do: "#{@api}/bot#{token}/#{method}"

  @doc "sendMessage body: chat_id + text, parse_mode only when asked."
  def payload(peer, text, opts \\ []) do
    base = %{chat_id: peer, text: text}
    if pm = opts[:parse_mode], do: Map.put(base, :parse_mode, pm), else: base
  end

  # ── inbound long-poller (supervised; token-gated in Application) ────────────

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    Process.send_after(self(), :poll, 1_000)
    {:ok, %{offset: 0, http: opts[:http]}}
  end

  @impl true
  def handle_info(:poll, state) do
    {state, delay} =
      try do
        case poll(state) do
          # Long poll: the request itself held 25s, so go straight back around.
          {:ok, state} -> {state, 0}
          {:error, reason} ->
            Logger.warning("telegram poll failed: #{inspect(reason)}")
            {state, 5_000}
        end
      rescue
        e ->
          Logger.warning("telegram poll crashed: #{Exception.message(e)}")
          {state, 5_000}
      end

    Process.send_after(self(), :poll, delay)
    {:noreply, state}
  end

  defp poll(state) do
    post = state.http || (&post_json/2)
    body = Jason.encode!(%{timeout: 25, offset: state.offset})

    case post.(url("getUpdates", token()), body) do
      {:ok, %{"ok" => true, "result" => updates}} ->
        Enum.each(updates, &handle_update(&1, http: state.http))
        offset = updates |> Enum.map(& &1["update_id"]) |> Enum.max(fn -> state.offset - 1 end) |> Kernel.+(1)
        {:ok, %{state | offset: offset}}

      {:ok, other} ->
        {:error, {:telegram, other["description"] || inspect(other)}}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Apply the DM policy to one update: allowed → persist to the JSONL inbox;
  unknown → reply with the pairing code. Public so tests drive it directly.
  """
  def handle_update(%{"message" => %{"chat" => %{"id" => chat_id}, "text" => text} = msg} = update, opts) do
    peer = to_string(chat_id)

    case Workbooks.Channels.check_sender("telegram", peer) do
      :allowed ->
        Workbooks.Channels.inbox_append("telegram", %{
          ts: System.system_time(:second),
          channel: "telegram",
          peer: peer,
          from: get_in(msg, ["from", "username"]),
          text: text,
          update_id: update["update_id"]
        })

      {:pairing, code} ->
        send_message(peer, "Workbooks pairing code: #{code}\nApprove with: wb channels approve telegram #{code}", opts)
        :ok
    end
  end

  def handle_update(_other, _opts), do: :ok

  # ── transport: :httpc, JSON in/out (the Llm idiom; 35s > the 25s long poll) ──
  defp post_json(url, body) do
    _ = Application.ensure_all_started(:inets)
    _ = Application.ensure_all_started(:ssl)

    case :httpc.request(:post, {String.to_charlist(url), [], ~c"application/json", body}, [timeout: 35_000], body_format: :binary) do
      {:ok, {{_, 200, _}, _, resp}} -> {:ok, Jason.decode!(resp)}
      {:ok, {{_, status, _}, _, resp}} -> {:error, {:http_status, status, String.slice(to_string(resp), 0, 200)}}
      {:error, reason} -> {:error, reason}
    end
  end
end
