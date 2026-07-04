defmodule Nexus.FishAudioTest do
  # async: false — some tests set process env (FISH_API_KEY).
  use ExUnit.Case, async: false
  alias Nexus.FishAudio

  @token "FISH_KEY_SHOULD_NEVER_LEAK"

  describe "build_request/4 (pure construction, no network)" do
    test "tts targets POST /v1/tts with the model header and NO auth header" do
      {method, url, headers, body} =
        FishAudio.build_request(:post, ["v1", "tts"], %{"text" => "hi", "format" => "mp3"},
          headers: [{"model", "s1"}], token: @token)

      assert method == :post
      assert url == "https://api.fish.audio/v1/tts"
      refute Enum.any?(headers, fn {k, _} -> k == "authorization" end)
      assert {"model", "s1"} in headers
      assert {"content-type", "application/json"} in headers
      assert Jason.decode!(body) == %{"text" => "hi", "format" => "mp3"}
    end

    test "GET carries no content-type and an empty body" do
      {_m, url, headers, body} = FishAudio.build_request(:get, ["wallet", "self", "api-credit"], nil)
      assert url == "https://api.fish.audio/wallet/self/api-credit"
      assert body == ""
      refute Enum.any?(headers, fn {k, _} -> k == "content-type" end)
    end
  end

  describe "tts/2" do
    test ":not_configured without an API key" do
      System.delete_env("FISH_API_KEY")
      assert FishAudio.tts("hello") == {:error, :not_configured}
    end

    test ":missing_text on blank input" do
      assert FishAudio.tts("", token: @token) == {:error, :missing_text}
      assert FishAudio.tts("   ", token: @token) == {:error, :missing_text}
    end

    test "returns raw audio bytes on 200 (non-JSON body passes through untouched)" do
      fake_mp3 = <<0xFF, 0xFB, 0x90, 0x00>> <> :crypto.strong_rand_bytes(64)

      http = fn :post, url, headers, body ->
        assert url == "https://api.fish.audio/v1/tts"
        assert {"model", "s2"} in headers
        decoded = Jason.decode!(body)
        assert decoded["text"] == "hello autopoet"
        assert decoded["latency"] == "balanced"
        assert decoded["reference_id"] == "voice_abc"
        {:ok, {200, fake_mp3}}
      end

      assert {:ok, ^fake_mp3} =
               FishAudio.tts("hello autopoet", model: "s2", reference_id: "voice_abc", http: http, token: @token)
    end

    test "the 402 insufficient-API-credit shape maps to a typed error" do
      http = fn _m, _u, _h, _b ->
        {:ok, {402, ~s({"message":"Insufficient API credit...","status":402})}}
      end

      assert {:error, {402, %{"message" => "Insufficient API credit" <> _}}} =
               FishAudio.tts("hi", http: http, token: @token)
    end
  end

  describe "tts_stream/3" do
    test "forwards chunks in order through the injectable stream seam" do
      chunks = [<<1, 1>>, <<2, 2>>, <<3, 3>>]

      http_stream = fn body, on_chunk ->
        assert body["text"] == "stream me"
        Enum.each(chunks, on_chunk)
        {:ok, 6}
      end

      collector = :ets.new(:chunks, [:public, :ordered_set])
      counter = :counters.new(1, [])

      on_chunk = fn c ->
        :counters.add(counter, 1, 1)
        :ets.insert(collector, {:counters.get(counter, 1), c})
      end

      assert {:ok, 6} = FishAudio.tts_stream("stream me", on_chunk, http_stream: http_stream, token: @token)
      got = :ets.tab2list(collector) |> Enum.sort() |> Enum.map(&elem(&1, 1))
      assert got == chunks
    end

    test ":not_configured / :missing_text fail closed before any request" do
      System.delete_env("FISH_API_KEY")
      assert FishAudio.tts_stream("hi", fn _ -> :ok end) == {:error, :not_configured}
      assert FishAudio.tts_stream("", fn _ -> :ok end, token: @token) == {:error, :missing_text}
    end
  end

  describe "asr/2" do
    test "encodes audio as base64 JSON" do
      http = fn :post, url, _h, body ->
        assert url == "https://api.fish.audio/v1/asr"
        decoded = Jason.decode!(body)
        assert Base.decode64!(decoded["audio"]) == <<1, 2, 3>>
        assert decoded["language"] == "en"
        {:ok, {200, ~s({"text":"hello"})}}
      end

      assert {:ok, %{"text" => "hello"}} = FishAudio.asr(<<1, 2, 3>>, language: "en", http: http, token: @token)
    end

    test ":missing_audio on empty input" do
      assert FishAudio.asr("", token: @token) == {:error, :missing_audio}
    end
  end

  describe "error mapping + token hygiene" do
    test "transport error is propagated as {:error, reason}" do
      http = fn _m, _u, _h, _b -> {:error, :timeout} end
      assert {:error, :timeout} = FishAudio.tts("hi", http: http, token: @token)
    end

    test "token absent from every returned value" do
      results = [
        FishAudio.tts("x", http: fn _, _, _, _ -> {:ok, {200, "audio"}} end, token: @token),
        FishAudio.tts("x", http: fn _, _, _, _ -> {:ok, {500, ~s({"e":"boom"})}} end, token: @token),
        FishAudio.tts("x", http: fn _, _, _, _ -> {:error, :nxdomain} end, token: @token),
        FishAudio.asr(<<1>>, http: fn _, _, _, _ -> {:ok, {200, "{}"}} end, token: @token)
      ]

      for r <- results do
        refute inspect(r) =~ @token
        refute inspect(r) =~ "Bearer"
      end
    end

    test "build_request output contains no token at all" do
      tuple = FishAudio.build_request(:post, ["v1", "tts"], %{"k" => "v"}, token: @token)
      refute inspect(tuple) =~ @token
      refute inspect(tuple) =~ "authorization"
    end

    test "FISH_API_KEY is on the privileged scrub list" do
      assert "FISH_API_KEY" in Nexus.Secrets.privileged_env_names()
    end
  end

  describe "TLS is verified (no MITM of the Fish API key)" do
    test "http_options pin verify_peer, a non-empty CA store, and the host SNI" do
      ssl = Keyword.fetch!(FishAudio.http_options(), :ssl)
      assert Keyword.get(ssl, :verify) == :verify_peer
      assert is_list(Keyword.get(ssl, :cacerts)) and Keyword.get(ssl, :cacerts) != []
      assert Keyword.get(ssl, :server_name_indication) == ~c"api.fish.audio"
      assert Keyword.has_key?(ssl, :customize_hostname_check)
    end

    test "api host is the fixed constant, never caller-supplied" do
      assert FishAudio.api_host() == "https://api.fish.audio"
    end
  end
end
