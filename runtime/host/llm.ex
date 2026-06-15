defmodule Workbooks.Llm do
  require Logger
  @moduledoc """
  The LLM client — OpenRouter (OpenAI-compatible chat/completions). The API key
  lives host-side (`OPENROUTER_API_KEY`); a Workbook/agent never sees it (the
  secrets-by-reference rule). `complete/2` is one turn: messages + tool specs in,
  a turn out (text content + any tool calls + finish reason). The agent loop
  (`Workbooks.Agent`) drives it until the model stops calling tools.

  HTTP is built-in `:httpc` (no new dep), with a small retry on transient errors.
  Default model is cheap (mimo); override per-call or via `WB_LLM_MODEL`.
  """
  @endpoint ~c"https://openrouter.ai/api/v1/chat/completions"
  @default_model "xiaomi/mimo-v2.5"

  @doc "The built-in default model id (used when nothing overrides it)."
  def default_model, do: @default_model

  @doc "The EFFECTIVE model id right now: WB_LLM_MODEL override, else the default."
  def effective_model, do: System.get_env("WB_LLM_MODEL") || @default_model

  @doc """
  One LLM turn. `messages` is a list of %{role, content, ...}; `tools` is a list
  of OpenAI tool specs (or []). Returns {:ok, %{content, tool_calls, finish, usage}}.
  """
  def complete(messages, opts \\ []) do
    # Streaming is opt-in: pass `on_delta` (a 1-arg fn called with each text
    # chunk as it arrives) and the turn is served over SSE. The accumulated
    # result has the SAME shape as the blocking path, so callers that don't pass
    # on_delta are unchanged.
    on_delta = opts[:on_delta]

    body =
      %{
        model: opts[:model] || System.get_env("WB_LLM_MODEL") || @default_model,
        messages: messages,
        temperature: opts[:temperature] || 0.4
      }
      |> maybe_put(:tools, opts[:tools])
      |> maybe_put(:tool_choice, opts[:tools] && "auto")
      |> maybe_put(:provider, opts[:provider])
      |> maybe_put(:stream, on_delta && true)
      |> maybe_put(:stream_options, on_delta && %{include_usage: true})
      |> Jason.encode!()

    # Hard outer bound: the per-request :httpc timeout has been observed not to
    # fire (runs stalling 10+ min inside one completion call), so the whole
    # post-with-retries is additionally wrapped in a killable Task. Worst case
    # is (retries+1) × 120s; the bound sits just above it.
    retries = opts[:retries] || 2
    deadline = (retries + 1) * 120_000 + 15_000
    t0 = System.monotonic_time(:millisecond)
    task = Task.async(fn -> if on_delta, do: post_stream(body, on_delta, retries), else: post(body, retries) end)

    result =
      case Task.yield(task, deadline) || Task.shutdown(task, :brutal_kill) do
        {:ok, r} -> r
        {:exit, reason} -> {:error, {:llm_crash, reason}}
        nil -> {:error, :llm_hard_timeout}
      end

    ms = System.monotonic_time(:millisecond) - t0

    if ms > 30_000 or match?({:error, _}, result) do
      Logger.info("Llm.complete: #{inspect(elem(result, 0))} after #{ms}ms")
    end

    result
  end

  defp post(body, retries) do
    :inets.start()
    :ssl.start()
    key = Workbooks.Secrets.get("OPENROUTER_API_KEY", "")
    headers = [{~c"authorization", ~c"Bearer #{key}"}, {~c"content-type", ~c"application/json"}]

    case :httpc.request(:post, {@endpoint, headers, ~c"application/json", body}, [timeout: 120_000], body_format: :binary) do
      {:ok, {{_, 200, _}, _, resp}} ->
        {:ok, parse(Jason.decode!(resp))}

      {:ok, {{_, status, _}, _, _resp}} when status in [408, 429, 500, 502, 503] and retries > 0 ->
        Process.sleep(1000)
        post(body, retries - 1)

      {:ok, {{_, status, _}, _, resp}} ->
        {:error, {:http, status, String.slice(to_string(resp), 0, 200)}}

      {:error, _reason} when retries > 0 ->
        Process.sleep(1000)
        post(body, retries - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Streaming (SSE) path ───────────────────────────────────────────────────
  # OpenRouter speaks OpenAI-style SSE: a series of `data: {json}` lines whose
  # choices[0].delta carries incremental `content` (text tokens) and tool_call
  # fragments, terminated by `data: [DONE]`. We accumulate into the same result
  # shape as parse/1 and call on_delta with each text chunk as it lands.
  defp post_stream(body, on_delta, retries) do
    :inets.start()
    :ssl.start()
    key = Workbooks.Secrets.get("OPENROUTER_API_KEY", "")
    headers = [{~c"authorization", ~c"Bearer #{key}"}, {~c"content-type", ~c"application/json"}]
    http_opts = [timeout: 120_000]
    req_opts = [sync: false, stream: :self, body_format: :binary]

    case :httpc.request(:post, {@endpoint, headers, ~c"application/json", body}, http_opts, req_opts) do
      {:ok, request_id} ->
        collect_stream(request_id, on_delta, %{content: "", tool_calls: %{}, finish: nil, usage: %{}}, "", retries, body)

      {:error, _reason} when retries > 0 ->
        Process.sleep(1000)
        post_stream(body, on_delta, retries - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Receive loop over the async :httpc stream messages. `buf` holds a partial SSE
  # tail between chunks; `acc` is the running result.
  defp collect_stream(req_id, on_delta, acc, buf, retries, body) do
    receive do
      {:http, {^req_id, :stream_start, _headers}} ->
        collect_stream(req_id, on_delta, acc, buf, retries, body)

      {:http, {^req_id, :stream, chunk}} ->
        {acc, buf} = consume_sse(buf <> chunk, on_delta, acc)
        collect_stream(req_id, on_delta, acc, buf, retries, body)

      {:http, {^req_id, :stream_end, _headers}} ->
        {:ok, finalize_stream(acc)}

      # A non-200 arrives as a single non-streamed reply; retry transient codes.
      {:http, {^req_id, {{_, status, _}, _hdrs, _resp}}} when status in [408, 429, 500, 502, 503] and retries > 0 ->
        Process.sleep(1000)
        post_stream(body, on_delta, retries - 1)

      {:http, {^req_id, {{_, status, _}, _hdrs, resp}}} ->
        {:error, {:http, status, String.slice(to_string(resp), 0, 200)}}

      {:http, {^req_id, {:error, _reason}}} when retries > 0 ->
        Process.sleep(1000)
        post_stream(body, on_delta, retries - 1)

      {:http, {^req_id, {:error, reason}}} ->
        {:error, reason}
    after
      120_000 -> {:error, :llm_stream_timeout}
    end
  end

  # Split off every COMPLETE SSE line ("...\n") from the buffer, apply each, and
  # return {acc, remaining_partial}.
  defp consume_sse(buf, on_delta, acc) do
    {lines, rest} = split_complete_lines(buf)
    acc = Enum.reduce(lines, acc, &apply_sse_line(&1, on_delta, &2))
    {acc, rest}
  end

  defp split_complete_lines(buf) do
    parts = String.split(buf, "\n")
    {complete, [partial]} = Enum.split(parts, length(parts) - 1)
    {complete, partial}
  end

  defp apply_sse_line(line, on_delta, acc) do
    case String.trim(line) do
      "" -> acc
      ":" <> _ -> acc
      "data: [DONE]" -> acc
      "data:" <> json -> apply_sse_data(String.trim(json), on_delta, acc)
      _ -> acc
    end
  end

  defp apply_sse_data(json, on_delta, acc) do
    case Jason.decode(json) do
      {:ok, %{"choices" => [choice | _]} = obj} ->
        delta = choice["delta"] || %{}
        acc = if is_binary(delta["content"]) and delta["content"] != "" do
          safe_emit(on_delta, delta["content"])
          %{acc | content: acc.content <> delta["content"]}
        else
          acc
        end

        acc = %{acc | tool_calls: merge_tool_call_deltas(acc.tool_calls, delta["tool_calls"])}
        acc = if choice["finish_reason"], do: %{acc | finish: choice["finish_reason"]}, else: acc
        if obj["usage"], do: %{acc | usage: obj["usage"]}, else: acc

      {:ok, %{"usage" => usage}} ->
        %{acc | usage: usage}

      _ ->
        acc
    end
  end

  # Tool-call deltas arrive fragmented, keyed by `index`; concatenate the
  # function.arguments string and fill id/name as they appear.
  defp merge_tool_call_deltas(tcs, nil), do: tcs

  defp merge_tool_call_deltas(tcs, deltas) when is_list(deltas) do
    Enum.reduce(deltas, tcs, fn d, acc ->
      idx = d["index"] || 0
      cur = Map.get(acc, idx, %{"id" => nil, "name" => nil, "arguments" => ""})
      fun = d["function"] || %{}

      merged = %{
        "id" => d["id"] || cur["id"],
        "name" => fun["name"] || cur["name"],
        "arguments" => cur["arguments"] <> (fun["arguments"] || "")
      }

      Map.put(acc, idx, merged)
    end)
  end

  defp finalize_stream(acc) do
    tool_calls =
      acc.tool_calls
      |> Enum.sort_by(fn {idx, _} -> idx end)
      |> Enum.map(fn {_idx, tc} ->
        %{id: tc["id"], name: tc["name"], args: decode_args(tc["arguments"])}
      end)

    content = if acc.content == "", do: nil, else: acc.content

    %{
      content: content,
      tool_calls: tool_calls,
      finish: acc.finish || "stop",
      usage: acc.usage,
      raw_message: %{"role" => "assistant", "content" => content}
    }
  end

  defp decode_args(nil), do: %{}
  defp decode_args(""), do: %{}
  defp decode_args(s), do: Jason.decode!(s)

  # on_delta is caller-supplied — never let a bad callback crash the stream.
  defp safe_emit(on_delta, chunk) do
    on_delta.(chunk)
  rescue
    _ -> :ok
  end

  defp parse(%{"choices" => [%{"message" => msg, "finish_reason" => finish} | _]} = resp) do
    %{
      content: msg["content"],
      tool_calls: parse_tool_calls(msg["tool_calls"]),
      finish: finish,
      usage: resp["usage"] || %{},
      raw_message: msg
    }
  end

  defp parse(other), do: %{content: nil, tool_calls: [], finish: "error", usage: %{}, raw_message: other}

  defp parse_tool_calls(nil), do: []

  defp parse_tool_calls(calls) do
    Enum.map(calls, fn c ->
      %{
        id: c["id"],
        name: c["function"]["name"],
        args: Jason.decode!(c["function"]["arguments"] || "{}")
      }
    end)
  end

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)
end
