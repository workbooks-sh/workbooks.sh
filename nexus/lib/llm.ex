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

  **Cloudflare Workers AI** is wired natively (no proxy): a model id starting with `workers-ai/` or
  `@cf/` routes to Cloudflare's OpenAI-compatible endpoint
  (`/client/v4/accounts/{CLOUDFLARE_ACCOUNT_ID}/ai/v1/chat/completions`), authed by the
  `CLOUDFLARE_API_TOKEN` secret. Both are read through `Nexus.Secrets` — never `System.get_env`. So
  `agent :x do model "workers-ai/meta/llama-3.3-70b-instruct-fp8-fast" end` runs on Cloudflare while
  everything else still flows through the configured OpenAI-compatible base_url (OpenRouter default).
  """

  @default_url "https://openrouter.ai/api/v1/chat/completions"
  @default_model "openai/gpt-4o-mini"

  @doc "The configured model (per-call `opts[:model]` wins)."
  def model(opts \\ []), do: opts[:model] || cfg(:model, @default_model)

  @doc """
  List models available from the configured provider. For OpenRouter (the default) this is a live
  `GET /models`; any OpenAI-compatible proxy exposing `/models` works too. Returns a list of
  `%{id, label}` (the configured default first). Falls back to a small curated set when no key is
  configured or the call fails — the model dropdown always has something to show.
  """
  def models(opts \\ []) do
    base = opts[:base_url] || cfg(:base_url, @default_url)
    key = api_key(opts)

    fetched =
      with k when k not in [nil, ""] <- key,
           {:ok, list} <- fetch_models(models_url(base), k) do
        list
      else
        _ -> default_models()
      end

    # When a Cloudflare token is configured, offer a curated set of Workers AI models too — they route
    # natively (no proxy), so they belong in the dropdown alongside the configured provider's list.
    fetched = if Nexus.Secrets.has?("CLOUDFLARE_API_TOKEN"), do: fetched ++ cf_models(), else: fetched

    # Pin the configured default to the top so it's the pre-selected option.
    default = model(opts)
    {head, rest} = Enum.split_with(fetched, &(&1.id == default))
    head ++ rest
  end

  # Curated Workers AI ids (our `workers-ai/…` convention; `Nexus.Llm` maps them to Cloudflare's `@cf/…`).
  defp cf_models do
    [
      %{id: "workers-ai/meta/llama-3.3-70b-instruct-fp8-fast", label: "Llama 3.3 70B · Workers AI"},
      %{id: "workers-ai/meta/llama-3.1-8b-instruct", label: "Llama 3.1 8B · Workers AI"},
      %{id: "workers-ai/qwen/qwen2.5-coder-32b-instruct", label: "Qwen2.5 Coder 32B · Workers AI"}
    ]
  end

  # Derive the `/models` URL from a chat/completions base_url (same host/version).
  defp models_url(base), do: String.replace(base, ~r{/chat/completions/?$}, "/models")

  defp fetch_models(url, key) do
    :inets.start()
    :ssl.start()
    headers = [{~c"authorization", ~c"Bearer #{key}"}]
    req = {String.to_charlist(url), headers}

    case :httpc.request(:get, req, [timeout: 15_000], body_format: :binary) do
      {:ok, {{_, 200, _}, _, resp}} ->
        case Jason.decode(resp) do
          {:ok, %{"data" => data}} when is_list(data) -> {:ok, normalize_models(data)}
          _ -> {:error, :bad_body}
        end

      _ ->
        {:error, :unavailable}
    end
  end

  defp normalize_models(data) do
    data
    |> Enum.map(fn m -> %{id: m["id"], label: m["name"] || m["id"]} end)
    |> Enum.filter(&(is_binary(&1.id) and &1.id != ""))
  end

  # Neutral fallback set (common OpenRouter ids) when the provider can't be reached.
  defp default_models do
    [
      %{id: "anthropic/claude-sonnet-4", label: "Claude Sonnet 4"},
      %{id: "anthropic/claude-3.5-haiku", label: "Claude 3.5 Haiku"},
      %{id: "openai/gpt-4o", label: "GPT-4o"},
      %{id: "openai/gpt-4o-mini", label: "GPT-4o mini"},
      %{id: "google/gemini-2.0-flash-001", label: "Gemini 2.0 Flash"},
      %{id: "meta-llama/llama-3.3-70b-instruct", label: "Llama 3.3 70B"}
    ]
  end

  @doc """
  One completion turn. `messages` = `[%{role, content}]` (+ tool messages); `opts[:tools]` = a list
  of OpenAI tool specs (or []). Returns `{:ok, %{content, tool_calls, finish, usage}} | {:error, _}`.
  """
  def complete(messages, opts \\ []) do
    {url, raw_key, mdl, account_ok?} = endpoint(opts)
    # Local llama-server (Constellation lanes) needs no key; a dummy bearer keeps the header well-formed.
    key =
      case raw_key do
        blank when blank in [nil, ""] -> if local?(url), do: "local"
        present -> present
      end

    cond do
      not account_ok? ->
        {:error, :no_cf_account}

      key in [nil, ""] ->
        {:error, :no_api_key}

      true ->
      body =
        %{model: mdl, messages: messages}
        |> maybe_put(:tools, opts[:tools])
        |> maybe_put(:temperature, opts[:temperature])
        |> maybe_put(:max_tokens, opts[:max_tokens])
        # Passthrough for server-specific knobs (e.g. llama.cpp `chat_template_kwargs` to toggle a
        # local thinking model's reasoning). Ignored by providers that don't recognize them.
        |> maybe_put(:chat_template_kwargs, opts[:chat_template_kwargs])
        # OpenRouter provider routing (e.g. %{order: ["Cloudflare"]}) — pin a fast/cheap provider.
        |> maybe_put(:provider, opts[:provider])
        # OpenRouter usage accounting: `%{include: true}` makes the response carry the REAL `cost`
        # (credits charged, incl. the web-search plugin) in `usage`, so callers can sum actual spend.
        |> maybe_put(:usage, opts[:usage])
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
      # OpenRouter `:online` web-search citations live here (url_citation), not always in content.
      annotations: msg["annotations"] || [],
      finish: choice["finish_reason"],
      usage: resp["usage"] || %{}
    }
  end

  defp parse(_), do: %{content: "", tool_calls: [], annotations: [], finish: "error", usage: %{}}

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
  defp api_key(opts), do: opts[:api_key] || Nexus.Secrets.get(cfg(:api_key_env, "OPENROUTER_API_KEY"))
  defp cfg(key, default), do: Keyword.get(Application.get_env(:nexus, __MODULE__, []), key, default)

  # Resolve the request endpoint: `{url, key, model, account_ok?}`. A `workers-ai/` or `@cf/` model id
  # routes to Cloudflare's OpenAI-compatible Workers AI endpoint (token + account via Nexus.Secrets);
  # everything else uses the configured base_url + key. `account_ok?` is false only when a CF model was
  # requested but no CLOUDFLARE_ACCOUNT_ID is set, so the caller fails loud instead of hitting a bad URL.
  defp endpoint(opts) do
    m = model(opts)

    if workers_ai?(m) do
      account = Nexus.Secrets.get("CLOUDFLARE_ACCOUNT_ID")
      url = "https://api.cloudflare.com/client/v4/accounts/#{account}/ai/v1/chat/completions"
      key = opts[:api_key] || Nexus.Secrets.get("CLOUDFLARE_API_TOKEN")
      {url, key, cf_model(m), account not in [nil, ""]}
    else
      {opts[:base_url] || cfg(:base_url, @default_url), api_key(opts), m, true}
    end
  end

  @doc "Is this a Cloudflare Workers AI model id? (`workers-ai/…` our convention, or a raw `@cf/…`)"
  def workers_ai?(model),
    do: is_binary(model) and (String.starts_with?(model, "workers-ai/") or String.starts_with?(model, "@cf/"))

  # Our `workers-ai/<vendor>/<model>` convention → Cloudflare's native `@cf/<vendor>/<model>` id.
  defp cf_model(m), do: String.replace_prefix(m, "workers-ai/", "@cf/")
end
