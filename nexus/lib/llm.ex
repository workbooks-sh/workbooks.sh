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

    case :httpc.request(:get, req, [timeout: 15_000] ++ Nexus.Net.tls_opts(), body_format: :binary) do
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
    {url, raw_key, mdl, account_ok?, endpoint_headers} = endpoint(opts)
    # Local llama-server (Constellation lanes) needs no key; a dummy bearer keeps the header well-formed.
    key =
      case raw_key do
        blank when blank in [nil, ""] -> if local?(url), do: "local"
        present -> present
      end

    # THE money boundary — the single routing EVERY paid call crosses. A paid call (remote provider: the CF
    # gateway / OpenRouter) resolves a billing tenant, is admitted here, and is metered here on success, so
    # NO caller can skip the gate or the ledger (a tenant-less paid call — e.g. KB authoring — still bills
    # the nexus's own org, never silently free). Local/free lanes (llama-server) bill no one.
    paid? = not local?(url)
    bill = billing_tenant(url, opts)
    admit = Nexus.Inference.Admission.admit(bill, model(opts), modality: :text)

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
        # OpenRouter unified reasoning control (e.g. %{enabled: false}) — a hybrid-reasoning
        # model on a latency lane must not think its whole token budget away (observed:
        # finish="length" with EMPTY content when reasoning ate all of max_tokens).
        |> maybe_put(:reasoning, opts[:reasoning])
        # OpenRouter usage accounting: `%{include: true}` makes the response carry the REAL `cost`
        # (credits charged, incl. the web-search plugin) in `usage`, so callers can sum actual spend.
        |> maybe_put(:usage, opts[:usage])
        |> Jason.encode!()

      # Long-running deep-research turns (thinking models + web plugin) can exceed the 2min default;
      # callers raise it via opts[:timeout] (ms).
      timeout = opts[:timeout] || 120_000

      # Extra headers: whatever the endpoint resolved (e.g. the Cloudflare AI
      # Gateway pass-through header `cf-aig-authorization`, so the vendor key rides
      # `authorization` and the gateway token rides alongside it) plus any the
      # caller supplied.
      extra = (opts[:extra_headers] || []) ++ endpoint_headers

      result =
        if stream?,
          do: post_stream(url, body, key, timeout, opts[:on_token], extra),
          else: post(url, body, opts[:retries] || 2, key, timeout, extra)

      # Meter a successful paid call that had NO explicit tenant (e.g. KB authoring) — it bills the nexus
      # org HERE, so it can never be both un-gated AND un-metered. Calls that pass an explicit tenant settle
      # their real catalog-priced cost at the caller (which holds the model price table), so we don't
      # double-charge them — but they STILL crossed the same gate above.
      # Meter on the ACTUAL routed model `mdl` (e.g. the CF fallback), not the requested default.
      if paid? and opts[:tenant] in [nil, ""], do: meter(result, bill, mdl)
      result
    end
  end

  # The tenant a paid call bills: an explicit opts[:tenant], else (for a remote/paid endpoint) the nexus's
  # own org — so a tenant-less paid call is still gated + metered, never silently free.
  defp billing_tenant(url, opts) do
    cond do
      is_binary(opts[:tenant]) and opts[:tenant] != "" -> opts[:tenant]
      local?(url) -> nil
      true -> Nexus.Auth.nexus_org()
    end
  end

  # Debit the billing tenant for a completed paid call (idempotent-safe, never raises). Streaming turns
  # carry usage only when the provider emits a final usage frame (we request `stream_options.include_usage`);
  # if absent, cost resolves to 0 — the GATE still applied, so a call is never both un-gated and un-metered.
  defp meter({:ok, turn}, tenant, model) when is_binary(tenant) do
    Nexus.Inference.Admission.charge(tenant, Nexus.Inference.Admission.cost(model, Map.get(turn, :usage, %{})))
  end

  defp meter(_, _, _), do: :ok

  @doc false
  # Test seam — drive the SSE→turn assembler over a list of raw chunks (split anywhere, incl. mid-event)
  # without a network call. Returns the assembled turn; `on_token` receives each content delta in order.
  def stream_assemble_for_test(chunks, on_token) when is_list(chunks) do
    st =
      Enum.reduce(chunks, %{buf: "", content: "", tools: %{}, finish: nil, usage: %{}}, fn chunk, acc ->
        consume_sse(acc.buf <> chunk, on_token, %{acc | buf: ""})
      end)

    %{content: st.content, tool_calls: assemble_tools(st.tools), finish: st.finish || "stop"}
  end

  # Streaming POST: receive Server-Sent Events (`data: {…}\n\n`), fire `on_token` per content delta, and
  # accumulate the full turn (content + streamed tool-call fragments) into the SAME shape `parse/1` returns.
  # Uses :httpc async streaming (no extra dep). Falls back to a synchronous parse on any stream error.
  defp post_stream(url, body, key, timeout, on_token, extra_headers \\ []) do
    :inets.start()
    :ssl.start()
    headers = [{~c"authorization", ~c"Bearer #{key}"}, {~c"content-type", ~c"application/json"}, {~c"accept", ~c"text/event-stream"}] ++ charlist_headers(extra_headers)
    req = {String.to_charlist(url), headers, ~c"application/json", body}

    case :httpc.request(:post, req, [timeout: timeout] ++ Nexus.Net.tls_opts(), [sync: false, stream: :self, body_format: :binary]) do
      {:ok, ref} -> stream_recv(ref, timeout, on_token, %{buf: "", content: "", tools: %{}, finish: nil, usage: %{}})
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
                annotations: [], finish: st.finish || "stop", usage: Map.get(st, :usage, %{})}}

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
      {:ok, %{} = ev} ->
        # A final usage frame (stream_options.include_usage) carries the token/cost totals — capture it so
        # streamed turns meter exactly like sync ones.
        st =
          case ev["usage"] do
            u when is_map(u) and map_size(u) > 0 -> %{st | usage: u}
            _ -> st
          end

        case ev do
          %{"choices" => [%{} = choice | _]} ->
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

  defp post(url, body, retries, key, timeout, extra_headers \\ []) do
    :inets.start()
    :ssl.start()
    headers = [{~c"authorization", ~c"Bearer #{key}"}, {~c"content-type", ~c"application/json"}] ++ charlist_headers(extra_headers)
    req = {String.to_charlist(url), headers, ~c"application/json", body}

    case :httpc.request(:post, req, [timeout: timeout] ++ Nexus.Net.tls_opts(), body_format: :binary) do
      {:ok, {{_, 200, _}, _, resp}} ->
        {:ok, parse(Jason.decode!(resp))}

      {:ok, {{_, status, _}, _, _}} when status in [408, 429, 500, 502, 503] and retries > 0 ->
        Process.sleep(800)
        post(url, body, retries - 1, key, timeout, extra_headers)

      {:ok, {{_, status, _}, _, resp}} ->
        {:error, {:http, status, String.slice(to_string(resp), 0, 200)}}

      {:error, _} when retries > 0 ->
        Process.sleep(800)
        post(url, body, retries - 1, key, timeout, extra_headers)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Extra request headers (charlist tuples for :httpc) — e.g. the Cloudflare AI
  # Gateway `cf-aig-authorization` pass-through token. Provider-agnostic.
  defp charlist_headers(pairs) do
    for {k, v} <- pairs, do: {String.to_charlist(to_string(k)), String.to_charlist(to_string(v))}
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
        {aig_url(), key, gateway_model(m), key not in [nil, ""], []}

      workers_ai?(m) ->
        account = Nexus.Secrets.get("CLOUDFLARE_ACCOUNT_ID")
        url = "https://api.cloudflare.com/client/v4/accounts/#{account}/ai/v1/chat/completions"
        key = opts[:api_key] || Nexus.Secrets.get("CLOUDFLARE_API_TOKEN")
        {url, key, cf_native(m), account not in [nil, ""], []}

      # GATEWAY-FIRST (opt-in via `gateway_upstream` config): when an upstream
      # provider is configured AND the AI Gateway is set, EVERY non-CF model rides
      # the gateway. The model is prefixed with the upstream slug (`xiaomi/mimo-v2.5`
      # → `openrouter/xiaomi/mimo-v2.5`) so ALL of a nexus's traffic flows through
      # one front door with caching + observability. Two auth shapes:
      #   * pass-through — a LOCAL upstream key exists: it rides `authorization`,
      #     the gateway token rides `cf-aig-authorization`.
      #   * BYOK (stored keys) — NO local upstream key: the provider key lives IN
      #     the gateway (AI Gateway → provider keys) and is injected upstream; the
      #     request authenticates with the gateway token alone. This is the shape
      #     where vendor keys never touch the client machine or app bundle.
      (up = gateway_upstream()) not in [nil, ""] and aig_url() not in [nil, ""] and aig_token() not in [nil, ""] ->
        case api_key(opts) do
          blank when blank in [nil, ""] ->
            {aig_url(), aig_token(), gateway_prefixed(m, up), true,
             [{"cf-aig-authorization", "Bearer " <> aig_token()}]}

          key ->
            {aig_url(), key, gateway_prefixed(m, up), true,
             [{"cf-aig-authorization", "Bearer " <> aig_token()}]}
        end

      true ->
        key = api_key(opts)
        cf = Nexus.Secrets.get("CF_AIG_TOKEN")
        # No provider key + the caller used the DEFAULT model + the CF AI Gateway is configured → route
        # through CF with a default Workers AI model rather than failing :no_api_key. Only when the model
        # wasn't explicitly requested, so an explicit non-CF model still fails loud (the caller chose it).
        if key in [nil, ""] and is_nil(opts[:model]) and aig_url() not in [nil, ""] and cf not in [nil, ""],
          do: {aig_url(), cf, gateway_model(@cf_fallback_model), true, []},
          else: {opts[:base_url] || cfg(:base_url, @default_url), key, m, true, []}
    end
  end

  # The upstream provider slug for gateway-first routing (config `gateway_upstream`,
  # e.g. "openrouter"). Empty/unset = the gateway pass-through lane is off and calls
  # go direct to the configured base_url (back-compat default).
  defp gateway_upstream, do: cfg(:gateway_upstream, "")
  defp aig_token, do: Nexus.Secrets.get("CF_AIG_TOKEN")

  # Prefix a bare model id with the upstream slug for the gateway compat endpoint,
  # unless it already carries it (or is a Workers AI id, handled above).
  @doc false
  def gateway_prefixed(m, upstream) do
    cond do
      workers_ai?(m) -> gateway_model(m)
      String.starts_with?(to_string(m), upstream <> "/") -> m
      true -> upstream <> "/" <> to_string(m)
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
