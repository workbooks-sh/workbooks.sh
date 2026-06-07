defmodule Workbooks.Llm do
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

  @doc """
  One LLM turn. `messages` is a list of %{role, content, ...}; `tools` is a list
  of OpenAI tool specs (or []). Returns {:ok, %{content, tool_calls, finish, usage}}.
  """
  def complete(messages, opts \\ []) do
    body =
      %{
        model: opts[:model] || System.get_env("WB_LLM_MODEL") || @default_model,
        messages: messages,
        temperature: opts[:temperature] || 0.4
      }
      |> maybe_put(:tools, opts[:tools])
      |> maybe_put(:tool_choice, opts[:tools] && "auto")
      |> Jason.encode!()

    post(body, opts[:retries] || 2)
  end

  defp post(body, retries) do
    :inets.start()
    :ssl.start()
    key = System.get_env("OPENROUTER_API_KEY") || ""
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
