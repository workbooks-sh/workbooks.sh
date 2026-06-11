defmodule Workbooks.Groundskeeper.Rehearsal do
  @moduledoc """
  The self-demo: a TEXT rehearsal of a groundskeeper conversation with no
  ElevenLabs and no human — the same persona (read from the def file) and the
  same five tools, with every tool call executed through the REAL /gk router
  (Plug.Test), so the whole bridge path is exercised: auth header, JSON
  marshalling, tool implementations, the task ledger.

  This exists because voice can't be CI: the founder isn't always on the
  call, and the convai key may not be provisioned. A rehearsal proves the
  conversation layer end-to-end; the only untested hop left is ElevenLabs'
  own telephony.

  `run/2` takes scripted founder lines; the groundskeeper side is a live LLM.
  The transcript (turns + tool calls) is written to <gk_home>/rehearsals/.
  """
  require Logger
  alias Workbooks.Groundskeeper

  @max_tool_rounds 6

  @doc """
  Rehearse a conversation: each founder line gets a groundskeeper reply (the
  LLM may call tools first). Returns %{turns: [...], file: path}.
  Options: :model (default WB_GK_BRAIN_MODEL or the Llm default).
  """
  def run(founder_lines, opts \\ []) when is_list(founder_lines) do
    model = opts[:model] || System.get_env("WB_GK_BRAIN_MODEL")
    system = %{role: "system", content: persona!()}

    {turns, _messages} =
      Enum.reduce(founder_lines, {[], [system]}, fn line, {turns, messages} ->
        messages = messages ++ [%{role: "user", content: line}]
        {reply, calls, messages} = complete_with_tools(messages, model, @max_tool_rounds, [])
        {turns ++ [%{founder: line, groundskeeper: reply, tool_calls: calls}], messages}
      end)

    file = write_transcript(turns)
    %{turns: turns, file: file}
  end

  # The agent loop: keep completing while the model calls tools.
  defp complete_with_tools(messages, model, rounds_left, calls) do
    llm_opts = [tools: tool_specs()] ++ if(model, do: [model: model], else: [])

    case Workbooks.Llm.complete(messages, llm_opts) do
      {:ok, %{tool_calls: tool_calls, raw_message: assistant}} when tool_calls != [] and rounds_left > 0 ->
        # Same echo convention as Workbooks.Agent: send back only what the API needs.
        stripped = Map.take(assistant, ["role", "content", "tool_calls"])

        {results, new_calls} =
          tool_calls
          |> Enum.map(fn tc ->
            result = call_bridge(tc.name, tc.args)
            {%{role: "tool", tool_call_id: tc.id, content: Jason.encode!(result)}, %{tool: tc.name, args: tc.args, result: result}}
          end)
          |> Enum.unzip()

        complete_with_tools(messages ++ [stripped] ++ results, model, rounds_left - 1, calls ++ new_calls)

      {:ok, %{content: content}} ->
        {content || "", calls, messages ++ [%{role: "assistant", content: content || ""}]}

      {:error, e} ->
        {"(llm error: #{inspect(e)})", calls, messages}
    end
  end

  # Through the REAL router — same path an ElevenLabs webhook takes.
  defp call_bridge(name, args) do
    secret = System.get_env("WB_GK_SECRET") || ""

    conn =
      Plug.Test.conn(:post, "/tool/#{name}", Jason.encode!(args))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("x-gk-secret", secret)
      |> Workbooks.Groundskeeper.Router.call(Workbooks.Groundskeeper.Router.init([]))

    case Jason.decode(conn.resp_body) do
      {:ok, decoded} -> decoded
      _ -> %{"raw" => conn.resp_body, "status" => conn.status}
    end
  end

  # The same five tools the ElevenLabs agent gets, in OpenAI tool-spec form.
  # Source of truth for shape: Workbooks.Groundskeeper.ElevenLabs.tools/1.
  defp tool_specs do
    [
      {"repo_state", "The ONLY source of truth about the repository. Call before ANY statement about project state.",
       %{query: %{type: "string", description: "summary | ready | issues | log"}}, []},
      {"capture", "Silently save a distilled thought (idea, decision, question, note). Do not read it back.",
       %{text: %{type: "string"}, kind: %{type: "string", description: "idea | decision | question | note"}}, ["text"]},
      {"file_issue", "File a tracked issue when the founder commits to work or names a bug.",
       %{title: %{type: "string"}, description: %{type: "string"}}, ["title"]},
      {"dispatch", "Send a background investigation goal to the runtime; results arrive later via tasks.",
       %{goal: %{type: "string"}}, ["goal"]},
      {"tasks", "List dispatched background tasks and fresh completions.", %{}, []}
    ]
    |> Enum.map(fn {name, desc, props, required} ->
      %{
        type: "function",
        function: %{
          name: name,
          description: desc,
          parameters: %{type: "object", properties: props, required: required}
        }
      }
    end)
  end

  defp persona! do
    path = Path.join([Groundskeeper.home(), "agent", "groundskeeper.org"])
    org = File.read!(path)

    case Regex.run(~r/^\*\* System prompt\n(.*?)(?=^\* |\z)/ms, org) do
      [_, prompt] -> String.trim(prompt)
      _ -> raise "no `** System prompt` heading in #{path}"
    end
  end

  defp write_transcript(turns) do
    dir = Path.join(Groundskeeper.home(), "rehearsals")
    File.mkdir_p!(dir)
    stamp = Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d-%H%M%S")
    file = Path.join(dir, "#{stamp}.org")

    body =
      turns
      |> Enum.map(fn t ->
        tools =
          t.tool_calls
          |> Enum.map(fn c -> "   - =#{c.tool}(#{Jason.encode!(c.args)})= → #{String.slice(Jason.encode!(c.result), 0, 200)}" end)
          |> Enum.join("\n")

        "* founder\n  #{t.founder}\n* groundskeeper\n  #{t.groundskeeper}\n" <>
          if(tools == "", do: "", else: "  tool calls:\n#{tools}\n")
      end)
      |> Enum.join("\n")

    File.write!(file, "#+TITLE: groundskeeper rehearsal — #{stamp}\n\n" <> body)
    file
  end
end
