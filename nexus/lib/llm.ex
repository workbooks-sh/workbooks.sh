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

  **Cloudflare Workers AI**, gateway-first: a model id `workers-ai/@cf/…` (or a raw `@cf/…`) routes to
  the Cloudflare **AI Gateway** OpenAI-compatible endpoint when `CF_AIG_URL`
  (`…/v1/{account}/{gateway}/compat/chat/completions`) + `CF_AIG_TOKEN` are set — one token, free
  routing, plus caching/observability. With no gateway it falls back to the direct Workers AI account
  endpoint (`/accounts/{CLOUDFLARE_ACCOUNT_ID}/ai/v1/chat/completions` + `CLOUDFLARE_API_TOKEN`). All
  read through `Nexus.Secrets`, never `System.get_env`, and nothing customer-specific is baked in (the
  URL is one config value). So `agent :x do model "workers-ai/@cf/meta/llama-3.3-70b-instruct-fp8-fast"
  end` runs on Cloudflare while everything else flows through the configured base_url (OpenRouter default).
  """

  @default_url "https://openrouter.ai/api/v1/chat/completions"
  @default_model "openai/gpt-4o-mini"
  # When no provider key is set but the Cloudflare AI Gateway IS (CF_AIG_URL + CF_AIG_TOKEN), default LLM
  # calls route here instead of failing :no_api_key — so a nexus that only configured CF "just works".
  @cf_fallback_model "workers-ai/@cf/meta/llama-3.3-70b-instruct-fp8-fast"

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

    # When Cloudflare inference is configured (AI Gateway token OR a direct Workers AI token), offer a
    # curated set of Workers AI models too — they route through the gateway/CF, so they belong in the
    # dropdown alongside the configured provider's list.
    cf? = Nexus.Secrets.has?("CF_AIG_TOKEN") or Nexus.Secrets.has?("CLOUDFLARE_API_TOKEN")
    fetched = if cf?, do: fetched ++ cf_models(), else: fetched

    # Pin the configured default to the top so it's the pre-selected option.
    default = model(opts)
    {head, rest} = Enum.split_with(fetched, &(&1.id == default))
    head ++ rest
  end

  # Curated Workers AI ids in the gateway compat form `workers-ai/@cf/<vendor>/<model>` (verified live).
  defp cf_models do
    [
      %{id: "workers-ai/@cf/meta/llama-3.3-70b-instruct-fp8-fast", label: "Llama 3.3 70B · Workers AI"},
      %{id: "workers-ai/@cf/meta/llama-3.1-8b-instruct-fast", label: "Llama 3.1 8B · Workers AI"},
      %{id: "workers-ai/@cf/meta/llama-3.1-70b-instruct", label: "Llama 3.1 70B · Workers AI"}
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

    # The money boundary: a per-tenant inference policy may refuse this call BEFORE it leaves the box
    # (out of credit, model not in the org's allow-list, over the monthly cap). Trusted/unconfigured
    # callers (`opts[:tenant]` nil, or no policy data) are always admitted — see Nexus.Inference.Admission.
    admit = Nexus.Inference.Admission.admit(opts[:tenant], model(opts), modality: :text)

    cond do
      match?({:error, _}, admit) ->
        {:error, {:inference_blocked, elem(admit, 1)}}

      not account_ok? ->
        {:error, :no_cf_account}

      key in [nil, ""] ->
        {:error, :no_api_key}

      true ->
      # Stream tokens when the caller supplies `on_token` (a 1-arg fn called with each content delta) —
      # the live channel uses it to surface the model's text as it's generated, not only at turn end.
      stream? = is_function(opts[:on_token], 1)

      body =
        %{model: mdl, messages: messages}
        |> maybe_put(:stream, stream? && true)
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
      timeout = opts[:timeout] || 120_000

      if stream?,
        do: post_stream(url, body, key, timeout, opts[:on_token]),
        else: post(url, body, opts[:retries] || 2, key, timeout)
    end
  end

  @doc false
  # Test seam — drive the SSE→turn assembler over a list of raw chunks (split anywhere, incl. mid-event)
  # without a network call. Returns the assembled turn; `on_token` receives each content delta in order.
  def stream_assemble_for_test(chunks, on_token) when is_list(chunks) do
    st =
      Enum.reduce(chunks, %{buf: "", content: "", tools: %{}, finish: nil}, fn chunk, acc ->
        consume_sse(acc.buf <> chunk, on_token, %{acc | buf: ""})
      end)

    %{content: st.content, tool_calls: assemble_tools(st.tools), finish: st.finish || "stop"}
  end

  # Streaming POST: receive Server-Sent Events (`data: {…}\n\n`), fire `on_token` per content delta, and
  # accumulate the full turn (content + streamed tool-call fragments) into the SAME shape `parse/1` returns.
  # Uses :httpc async streaming (no extra dep). Falls back to a synchronous parse on any stream error.
  defp post_stream(url, body, key, timeout, on_token) do
    :inets.start()
    :ssl.start()
    headers = [{~c"authorization", ~c"Bearer #{key}"}, {~c"content-type", ~c"application/json"}, {~c"accept", ~c"text/event-stream"}]
    req = {String.to_charlist(url), headers, ~c"application/json", body}

    case :httpc.request(:post, req, [timeout: timeout], [sync: false, stream: :self, body_format: :binary]) do
      {:ok, ref} -> stream_recv(ref, timeout, on_token, %{buf: "", content: "", tools: %{}, finish: nil})
      {:error, reason} -> {:error, reason}
    end
  end

  defp stream_recv(ref, timeout, on_token, st) do
    receive do
      {:http, {^ref, :stream_start, _headers}} -> stream_recv(ref, timeout, on_token, st)

      {:http, {^ref, :stream, chunk}} ->
        st = consume_sse(st.buf <> chunk, on_token, %{st | buf: ""})
        stream_recv(ref, timeout, on_token, st)

      {:http, {^ref, :stream_end, _headers}} ->
        {:ok, %{content: st.content, tool_calls: assemble_tools(st.tools),
                annotations: [], finish: st.finish || "stop", usage: %{}}}

      {:http, {^ref, {:error, reason}}} ->
        {:error, reason}

      {:http, {^ref, {{_, status, _}, _h, resp}}} ->
        {:error, {:http, status, String.slice(to_string(resp), 0, 200)}}
    after
      timeout -> :httpc.cancel_request(ref); {:error, :stream_timeout}
    end
  end

  # Split the buffer into complete SSE events (`\n\n`-delimited), parse each `data:` line, keep the
  # trailing partial in `buf` for the next chunk.
  defp consume_sse(data, on_token, st) do
    parts = String.split(data, "\n\n")
    {complete, [rest]} = Enum.split(parts, -1)
    st = Enum.reduce(complete, st, fn ev, acc -> apply_sse_event(ev, on_token, acc) end)
    %{st | buf: rest}
  end

  defp apply_sse_event(event, on_token, st) do
    event
    |> String.split("\n", trim: true)
    |> Enum.reduce(st, fn line, acc ->
      case String.trim(line) do
        "data: [DONE]" -> acc
        "data: " <> json -> apply_delta(json, on_token, acc)
        _ -> acc
      end
    end)
  end

  defp apply_delta(json, on_token, st) do
    case Jason.decode(json) do
      {:ok, %{"choices" => [%{} = choice | _]}} ->
        delta = choice["delta"] || %{}
        st = if choice["finish_reason"], do: %{st | finish: choice["finish_reason"]}, else: st

        st =
          case delta["content"] do
            c when is_binary(c) and c != "" -> on_token.(c); %{st | content: st.content <> c}
            _ -> st
          end

        Enum.reduce(delta["tool_calls"] || [], st, &accumulate_tool_delta/2)

      _ ->
        st
    end
  end

  # Tool calls stream as fragments keyed by `index`: id/name arrive once, `arguments` concatenate.
  defp accumulate_tool_delta(tc, st) do
    idx = tc["index"] || 0
    fun = tc["function"] || %{}
    cur = Map.get(st.tools, idx, %{id: nil, name: nil, args: ""})
    merged = %{
      id: tc["id"] || cur.id,
      name: fun["name"] || cur.name,
      args: cur.args <> (fun["arguments"] || "")
    }
    %{st | tools: Map.put(st.tools, idx, merged)}
  end

  defp assemble_tools(tools) do
    tools
    |> Enum.sort_by(fn {idx, _} -> idx end)
    |> Enum.map(fn {_idx, %{id: id, name: name, args: args}} ->
      parsed = case Jason.decode(args) do
        {:ok, m} when is_map(m) -> m
        _ -> %{}
      end
      %{id: id, name: name, args: parsed}
    end)
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

  # Resolve the request endpoint: `{url, key, model, ok?}`. A Workers AI model id (`workers-ai/@cf/…`
  # or a raw `@cf/…`) prefers the Cloudflare **AI Gateway** compat endpoint when configured (`CF_AIG_URL`
  # + `CF_AIG_TOKEN` — one token, free routing, caching + observability), else falls back to the direct
  # Workers AI account endpoint (`CLOUDFLARE_API_TOKEN` + `CLOUDFLARE_ACCOUNT_ID`). Everything else uses
  # the configured base_url + key. `ok?` is false only when a CF model was requested but neither route is
  # fully configured, so the caller fails loud (:no_cf_account) instead of POSTing a broken URL.
  defp endpoint(opts) do
    m = model(opts)

    cond do
      workers_ai?(m) and aig_url() not in [nil, ""] ->
        key = opts[:api_key] || Nexus.Secrets.get("CF_AIG_TOKEN")
        {aig_url(), key, gateway_model(m), key not in [nil, ""]}

      workers_ai?(m) ->
        account = Nexus.Secrets.get("CLOUDFLARE_ACCOUNT_ID")
        url = "https://api.cloudflare.com/client/v4/accounts/#{account}/ai/v1/chat/completions"
        key = opts[:api_key] || Nexus.Secrets.get("CLOUDFLARE_API_TOKEN")
        {url, key, cf_native(m), account not in [nil, ""]}

      true ->
        key = api_key(opts)
        cf = Nexus.Secrets.get("CF_AIG_TOKEN")
        # No provider key + the caller used the DEFAULT model + the CF AI Gateway is configured → route
        # through CF with a default Workers AI model rather than failing :no_api_key. Only when the model
        # wasn't explicitly requested, so an explicit non-CF model still fails loud (the caller chose it).
        if key in [nil, ""] and is_nil(opts[:model]) and aig_url() not in [nil, ""] and cf not in [nil, ""],
          do: {aig_url(), cf, gateway_model(@cf_fallback_model), true},
          else: {opts[:base_url] || cfg(:base_url, @default_url), key, m, true}
    end
  end

  @doc "Is this a Cloudflare Workers AI model id? (`workers-ai/…` our convention, or a raw `@cf/…`)"
  def workers_ai?(model),
    do: is_binary(model) and (String.starts_with?(model, "workers-ai/") or String.starts_with?(model, "@cf/"))

  # The full AI Gateway compat endpoint URL (`…/v1/{account}/{gateway}/compat/chat/completions`), set as
  # one secret/config value so the runtime bakes in nothing customer-specific.
  defp aig_url, do: Nexus.Secrets.get("CF_AIG_URL")

  @doc "Gateway compat model form: `workers-ai/@cf/<vendor>/<model>` (provider prefix + native CF id)."
  def gateway_model("workers-ai/" <> _ = m), do: m
  def gateway_model("@cf/" <> _ = m), do: "workers-ai/" <> m
  def gateway_model(m), do: m

  @doc "Direct-endpoint model form: the native `@cf/<vendor>/<model>` id (no provider prefix)."
  def cf_native(m), do: String.replace_prefix(m, "workers-ai/", "")
end
