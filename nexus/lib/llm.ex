defmodule Nexus.Llm do
  @moduledoc """
  The LLM client — one turn of an OpenAI-compatible chat/completions API. `complete/2` takes
  `messages` (and optional `tools`) and returns `{:ok, %{content, tool_calls, finish, usage}}`.
  `Nexus.Agent` drives it in a loop until the model stops calling tools.

  **Provider-agnostic via `base_url`.** Defaults to **OpenRouter**; point it at **LiteLLM** (or any
  OpenAI-compatible proxy / self-hosted server) to route across providers behind one endpoint:

      config :nexus, Nexus.Llm,
        base_url: "https://openrouter.ai/api/v1/chat/completions",  # default
        # or a LiteLLM proxy: "http://localhost:4000/v1/chat/completions"
        model: "openai/gpt-4o-mini",
        api_key_env: "OPENROUTER_API_KEY"   # which env var holds the key (LITELLM_API_KEY, etc.)

  The key lives host-side (env), never in a workbook/agent. Built-in `:httpc`, retry on transient errors.
  """

  @default_url "https://openrouter.ai/api/v1/chat/completions"
  @default_model "openai/gpt-4o-mini"

  @doc "The configured model (per-call `opts[:model]` wins)."
  def model(opts \\ []), do: opts[:model] || cfg(:model, @default_model)

  @doc """
  One completion turn. `messages` = `[%{role, content}]` (+ tool messages); `opts[:tools]` = a list
  of OpenAI tool specs (or []). Returns `{:ok, %{content, tool_calls, finish, usage}} | {:error, _}`.
  """
  def complete(messages, opts \\ []) do
    url = opts[:base_url] || cfg(:base_url, @default_url)
    # Local llama-server (Constellation lanes) needs no key; a dummy bearer keeps the header well-formed.
    key =
      case api_key(opts) do
        blank when blank in [nil, ""] -> if local?(url), do: "local"
        present -> present
      end

    if key in [nil, ""] do
      {:error, :no_api_key}
    else
      body =
        %{model: model(opts), messages: messages}
        |> maybe_put(:tools, opts[:tools])
        |> maybe_put(:temperature, opts[:temperature])
        |> maybe_put(:max_tokens, opts[:max_tokens])
        # Passthrough for server-specific knobs (e.g. llama.cpp `chat_template_kwargs` to toggle a
        # local thinking model's reasoning). Ignored by providers that don't recognize them.
        |> maybe_put(:chat_template_kwargs, opts[:chat_template_kwargs])
        # OpenRouter provider routing (e.g. %{order: ["Cloudflare"]}) — pin a fast/cheap provider.
        |> maybe_put(:provider, opts[:provider])
        |> Jason.encode!()

      # Long-running deep-research turns (thinking models + web plugin) can exceed the 2min default;
      # callers raise it via opts[:timeout] (ms).
      post(url, body, opts[:retries] || 2, key, opts[:timeout] || 120_000)
    end
  end

  defp post(url, body, retries, key, timeout) do
    :inets.start()
    :ssl.start()
    headers = [{~c"authorization", ~c"Bearer #{key}"}, {~c"content-type", ~c"application/json"}]
    req = {String.to_charlist(url), headers, ~c"application/json", body}

    case :httpc.request(:post, req, [timeout: timeout], body_format: :binary) do
      {:ok, {{_, 200, _}, _, resp}} ->
        {:ok, parse(Jason.decode!(resp))}

      {:ok, {{_, status, _}, _, _}} when status in [408, 429, 500, 502, 503] and retries > 0 ->
        Process.sleep(800)
        post(url, body, retries - 1, key, timeout)

      {:ok, {{_, status, _}, _, resp}} ->
        {:error, {:http, status, String.slice(to_string(resp), 0, 200)}}

      {:error, _} when retries > 0 ->
        Process.sleep(800)
        post(url, body, retries - 1, key, timeout)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Normalize a decoded provider response (the JSON body as a map) into our turn shape. Public so the
  robustness of the parse — adversarial/malformed payloads must degrade gracefully, never raise — can
  be asserted without a live call. Tolerates: no `choices`, missing `message`, `tool_calls` with
  missing id/name, and `arguments` that are absent / not JSON / not an object.
  """
  def parse_response(decoded), do: parse(decoded)

  # Normalize an OpenAI/OpenRouter response into our turn shape.
  defp parse(%{"choices" => [choice | _]} = resp) do
    msg = choice["message"] || %{}

    %{
      content: msg["content"] || "",
      tool_calls: parse_tool_calls(msg["tool_calls"] || []),
      finish: choice["finish_reason"],
      usage: resp["usage"] || %{}
    }
  end

  defp parse(_), do: %{content: "", tool_calls: [], finish: "error", usage: %{}}

  defp parse_tool_calls(calls) do
    Enum.map(calls, fn c ->
      fun = c["function"] || %{}
      args = case Jason.decode(fun["arguments"] || "{}") do
        {:ok, m} when is_map(m) -> m
        _ -> %{}
      end

      %{id: c["id"], name: fun["name"], args: args}
    end)
  end

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, _k, []), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)

  defp local?(url), do: String.contains?(url, "127.0.0.1") or String.contains?(url, "localhost")
  defp api_key(opts), do: opts[:api_key] || System.get_env(cfg(:api_key_env, "OPENROUTER_API_KEY"))
  defp cfg(key, default), do: Keyword.get(Application.get_env(:nexus, __MODULE__, []), key, default)
end
