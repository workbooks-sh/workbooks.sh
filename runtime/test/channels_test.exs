defmodule Workbooks.ChannelsTest do
  @moduledoc """
  Channels slice 1 (registry + DM policy + Telegram adapter). Hermetic: WB_DATA
  points at a per-run tmp dir, and every HTTP call goes through an injected stub
  (the DataSource.Http / CLI.Runtime idiom) — no live network, no live token.
  """
  use ExUnit.Case, async: false

  alias Workbooks.Channels
  alias Workbooks.Channels.Telegram

  setup do
    prev_data = System.get_env("WB_DATA")
    prev_token = System.get_env("TELEGRAM_BOT_TOKEN")
    tmp = Path.join(System.tmp_dir!(), "wb-channels-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    System.put_env("WB_DATA", tmp)

    on_exit(fn ->
      if prev_data, do: System.put_env("WB_DATA", prev_data), else: System.delete_env("WB_DATA")
      if prev_token, do: System.put_env("TELEGRAM_BOT_TOKEN", prev_token), else: System.delete_env("TELEGRAM_BOT_TOKEN")
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  describe "registry" do
    test "list/0 reports telegram with its configured flag" do
      System.delete_env("TELEGRAM_BOT_TOKEN")
      assert [%{channel: "telegram", configured: false}] = Channels.list()

      System.put_env("TELEGRAM_BOT_TOKEN", "123:abc")
      assert [%{channel: "telegram", configured: true}] = Channels.list()
    end

    test "send to an unknown channel" do
      assert {:error, :unknown_channel} = Channels.send("carrier-pigeon", "p", "hi")
    end

    test "send to an unconfigured channel" do
      System.delete_env("TELEGRAM_BOT_TOKEN")
      assert {:error, :not_configured} = Channels.send("telegram", "p", "hi")
    end

    test "send routes to the adapter when configured (stubbed http)" do
      System.put_env("TELEGRAM_BOT_TOKEN", "123:abc")
      stub = fn _url, _body -> {:ok, %{"ok" => true}} end
      assert {:ok, %{channel: "telegram", peer: "42"}} = Channels.send("telegram", "42", "hi", http: stub)
    end
  end

  describe "DM policy (pairing-code lifecycle)" do
    test "unknown sender gets a code, the same code on repeat, then approval allows" do
      assert {:pairing, code} = Channels.check_sender("telegram", "555")
      assert String.length(code) == 6

      # Idempotent: a second message doesn't mint a second code.
      assert {:pairing, ^code} = Channels.check_sender("telegram", "555")

      assert {:ok, "555"} = Channels.approve("telegram", code)
      assert :allowed = Channels.check_sender("telegram", "555")

      # The code is consumed.
      assert :not_found = Channels.approve("telegram", code)
    end

    test "approving a bogus code" do
      assert :not_found = Channels.approve("telegram", "NOPE99")
    end

    test "allowlist persists to WB_DATA/channels/allow-telegram.json", %{tmp: tmp} do
      {:pairing, code} = Channels.check_sender("telegram", "777")
      {:ok, _} = Channels.approve("telegram", code)

      state = Path.join([tmp, "channels", "allow-telegram.json"]) |> File.read!() |> Jason.decode!()
      assert state["approved"] == ["777"]
      assert state["pending"] == %{}
    end
  end

  describe "telegram adapter (URL + payload, stubbed http)" do
    test "url/2 builds the Bot API method URL" do
      assert Telegram.url("sendMessage", "123:abc") == "https://api.telegram.org/bot123:abc/sendMessage"
    end

    test "payload includes parse_mode only when asked" do
      assert Telegram.payload("42", "hi") == %{chat_id: "42", text: "hi"}
      assert Telegram.payload("42", "hi", parse_mode: "Markdown") == %{chat_id: "42", text: "hi", parse_mode: "Markdown"}
    end

    test "send_message posts the sendMessage URL + JSON body" do
      stub = fn url, body ->
        assert url == "https://api.telegram.org/bot123:abc/sendMessage"
        assert Jason.decode!(body) == %{"chat_id" => "42", "text" => "hello"}
        {:ok, %{"ok" => true}}
      end

      assert {:ok, %{channel: "telegram", peer: "42"}} = Telegram.send_message("42", "hello", http: stub, token: "123:abc")
    end

    test "a Bot API error surfaces as {:error, {:telegram, description}}" do
      stub = fn _url, _body -> {:ok, %{"ok" => false, "description" => "chat not found"}} end
      assert {:error, {:telegram, "chat not found"}} = Telegram.send_message("42", "x", http: stub, token: "123:abc")
    end
  end

  describe "telegram inbound (handle_update through the policy)" do
    @update %{
      "update_id" => 9,
      "message" => %{"chat" => %{"id" => 314}, "from" => %{"username" => "shane"}, "text" => "yo"}
    }

    test "unknown sender is replied a pairing code, nothing reaches the inbox", %{tmp: tmp} do
      me = self()
      stub = fn url, body -> send(me, {:sent, url, Jason.decode!(body)}); {:ok, %{"ok" => true}} end
      System.put_env("TELEGRAM_BOT_TOKEN", "123:abc")

      assert :ok = Telegram.handle_update(@update, http: stub)

      assert_receive {:sent, url, %{"chat_id" => "314", "text" => text}}
      assert url =~ "/sendMessage"
      assert text =~ "pairing code"
      refute File.exists?(Path.join([tmp, "channels", "telegram-inbox.jsonl"]))
    end

    test "allowed sender's message is persisted to the JSONL inbox", %{tmp: tmp} do
      {:pairing, code} = Channels.check_sender("telegram", "314")
      {:ok, _} = Channels.approve("telegram", code)

      assert :ok = Telegram.handle_update(@update, http: fn _, _ -> flunk("no send expected") end)

      [line] = Path.join([tmp, "channels", "telegram-inbox.jsonl"]) |> File.read!() |> String.split("\n", trim: true)
      record = Jason.decode!(line)
      assert %{"peer" => "314", "from" => "shane", "text" => "yo", "update_id" => 9, "channel" => "telegram"} = record
    end

    test "non-message updates are ignored" do
      assert :ok = Telegram.handle_update(%{"update_id" => 1, "edited_message" => %{}}, [])
    end
  end
end
