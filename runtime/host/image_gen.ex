defmodule Workbooks.ImageGen do
  require Logger

  @moduledoc """
  HOST-BROKERED image generation — wb-9ja's trust model, extended to pixels.

  An in-sandbox agent can ask for an editorial image (a banner, an illustration)
  by supplying only INTENT: a prompt + an aspect. The HOST holds the key and the
  network. The agent never sees `OPENROUTER_API_KEY`, never chooses an HTTP
  endpoint, never forks a process — exactly like `git`/`publish`. This module is
  the thin host capability the `image` TOOL reaches: it calls OpenRouter's
  image-generation lane (chat/completions with `modalities: ["image","text"]`),
  pulls the returned `data:` URI out of `images[0].image_url.url`, base64-decodes
  it, and hands the raw bytes back to the tool clause, which writes them under the
  agent's workdir (with the same path-traversal guard as `publish`).

  ── Why this is NOT the agent executing native code ──────────────────────────
  Same argument as SitePublish: the agent chooses NOTHING about HOW the call runs
  — not the endpoint, not the key, not the model, not the wire format. The host
  fixes all of that. The agent supplies a prompt; pure Elixir (`:httpc`) performs
  a single, constrained HTTPS POST. No shell, no subprocess, no arbitrary command.

  Model is `WB_IMAGE_MODEL` (default `google/gemini-2.5-flash-image`). The OpenAI
  image lane lacks a size param for all models, so aspect is folded into the
  prompt as a composition suffix.

  ── Test seam ────────────────────────────────────────────────────────────────
  `WB_IMAGE_FAKE=1` short-circuits the network and returns a real 1×1 WEBP — the
  same env-flag style llm.ex tests use to avoid live HTTP. No mock framework.
  """
  @endpoint ~c"https://openrouter.ai/api/v1/chat/completions"
  @default_model "google/gemini-2.5-flash-image"

  # A real, minimal 1×1 lossless WEBP (RIFF/VP8L) — returned in fake mode so tests
  # exercise the full decode/write path against actual image bytes.
  @fake_webp Base.decode64!("UklGRhoAAABXRUJQVlA4TA0AAAAvAAAAEAcQEYf/UWg/AA==")

  @doc """
  Generate an image from `prompt` at `aspect` ("16:9" | "1:1" | "3:1").
  Returns `{:ok, binary}` (the decoded image bytes) or `{:error, term}`.
  """
  def generate(prompt, aspect \\ "16:9") when is_binary(prompt) do
    full = prompt <> aspect_suffix(aspect)

    if System.get_env("WB_IMAGE_FAKE") == "1" do
      {:ok, @fake_webp}
    else
      request(full)
    end
  end

  # Aspect maps to a prompt-composition suffix (the API has no size param across
  # all models). Unknown aspects fall back to the 16:9 banner framing.
  defp aspect_suffix("1:1"), do: " — square 1:1 composition"
  defp aspect_suffix("3:1"), do: " — ultra-wide 3:1 banner composition"
  defp aspect_suffix(_), do: " — wide 16:9 banner composition"

  defp request(prompt) do
    :inets.start()
    :ssl.start()
    key = System.get_env("OPENROUTER_API_KEY") || ""
    model = System.get_env("WB_IMAGE_MODEL") || @default_model

    body =
      %{
        model: model,
        modalities: ["image", "text"],
        messages: [%{role: "user", content: prompt}]
      }
      |> Jason.encode!()

    headers = [{~c"authorization", ~c"Bearer #{key}"}, {~c"content-type", ~c"application/json"}]

    case :httpc.request(
           :post,
           {@endpoint, headers, ~c"application/json", body},
           [timeout: 110_000],
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _, resp}} ->
        decode_image(resp)

      {:ok, {{_, status, _}, _, resp}} ->
        {:error, {:http, status, String.slice(to_string(resp), 0, 200)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Pull images[0].image_url.url (a `data:<mime>;base64,<payload>` URI) out of the
  # OpenAI-shaped response and base64-decode the payload to raw bytes.
  defp decode_image(resp) do
    with {:ok, json} <- Jason.decode(resp),
         %{"choices" => [%{"message" => msg} | _]} <- json,
         [%{"image_url" => %{"url" => uri}} | _] <- msg["images"] || [],
         {:ok, bin} <- decode_data_uri(uri) do
      {:ok, bin}
    else
      {:error, _} = e -> e
      _ -> {:error, {:no_image, String.slice(to_string(resp), 0, 200)}}
    end
  end

  defp decode_data_uri("data:" <> rest) do
    case String.split(rest, ",", parts: 2) do
      [_meta, payload] ->
        case Base.decode64(payload) do
          {:ok, bin} -> {:ok, bin}
          :error -> {:error, :bad_base64}
        end

      _ ->
        {:error, :bad_data_uri}
    end
  end

  defp decode_data_uri(_), do: {:error, :not_a_data_uri}
end
