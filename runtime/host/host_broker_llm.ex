defmodule Workbooks.HostBrokerLLM do
  @moduledoc """
  HOST-PERFORMED LLM completion for the SM agent loop (shared by the `Workbooks.HostBroker` sync import AND
  the legacy `Workbooks.ExecLoopback` `/__wb/llm` fetch route). The guest sends prompt + tools + conversation
  in Claude-Messages shape and gets the model's next move back; the API key is held by the HOST and the egress
  is performed here, so the key never crosses the sandbox membrane.

  Two backends behind ONE Claude-Messages-shaped surface (the harness is provider-agnostic — it reads
  `stop_reason` + content blocks):

    * MOCK (default, hermetic) — a deterministic two-step Claude-Messages exchange: first call returns a
      `tool_use` block (the model decides to run a tool); once a `tool_result` is present it returns the final
      `text` answer quoting the tool output. Drives the multi-round tool loop end-to-end without a network
      dependency, so the residency THESIS test stays deterministic.

    * LIVE (`WB_HARNESS_LLM=live`, or a grant carrying `:llm_live`) — calls `Workbooks.Llm.complete/2`
      (OpenRouter, host-held `OPENROUTER_API_KEY`) and re-shapes its OpenAI-style result into the
      Claude-Messages blocks the harness parses. Same surface; a real provider swaps in with no harness change.
  """

  @doc """
  Complete one turn. `messages` is the Claude-Messages history; `tools` the tool specs; `grant` the session
  grant (for the live/mock decision + future per-tenant model routing). Returns a Claude-Messages-shaped
  assistant message map.
  """
  def complete(messages, tools \\ [], grant \\ nil) do
    if live?(grant), do: live(messages, tools, grant), else: mock(messages)
  end

  defp live?(grant) do
    System.get_env("WB_HARNESS_LLM") == "live" or (is_map(grant) and Map.get(grant, :llm_live) == true)
  end

  # ── deterministic mock (Claude Messages) ───────────────────────────────────────────────────────

  defp mock(messages) do
    case find_tool_result(messages) do
      nil ->
        %{
          "id" => "msg_wb_llm_tool",
          "type" => "message",
          "role" => "assistant",
          "stop_reason" => "tool_use",
          "content" => [
            %{"type" => "text", "text" => "I'll count the matching lines."},
            %{
              "type" => "tool_use",
              "id" => "toolu_wb_1",
              "name" => "run_command",
              "input" => %{
                "command" => "grep",
                "args" => ["needle"],
                "stdin" => "needle\nhay\nneedle\nstraw\nneedle\n"
              }
            }
          ]
        }

      tool_result ->
        %{
          "id" => "msg_wb_llm_final",
          "type" => "message",
          "role" => "assistant",
          "stop_reason" => "end_turn",
          "content" => [
            %{"type" => "text", "text" => "The repository has #{String.trim(tool_result)} matching lines."}
          ]
        }
    end
  end

  # Does the LAST message carry a tool_result block? (so a multi-turn conversation — where earlier turns
  # already resolved their tool calls — still asks for a fresh tool_use on each NEW turn; only the message
  # that immediately followed THIS turn's tool_use yields the final answer). Returns its text, or nil.
  defp find_tool_result(messages) do
    case List.last(messages) do
      %{"content" => content} when is_list(content) ->
        Enum.find_value(content, fn b ->
          if is_map(b) and b["type"] == "tool_result" do
            case b["content"] do
              t when is_binary(t) -> t
              [%{"text" => t} | _] -> t
              _ -> nil
            end
          end
        end)

      _ ->
        nil
    end
  end

  # ── live backend (Workbooks.Llm → Claude-Messages reshape) ─────────────────────────────────────

  defp live(messages, tools, grant) do
    opts = if is_map(grant) and is_binary(grant[:model]), do: [model: grant[:model]], else: []
    opts = if tools == [], do: opts, else: Keyword.put(opts, :tools, tools)

    case Workbooks.Llm.complete(messages, opts) do
      {:ok, result} -> reshape(result)
      {:error, reason} -> error_message(reason)
    end
  end

  # Re-shape Workbooks.Llm's {content, tool_calls, finish, ...} into Claude-Messages content blocks.
  defp reshape(result) do
    tool_calls = Map.get(result, :tool_calls) || Map.get(result, "tool_calls") || []
    text = Map.get(result, :content) || Map.get(result, "content") || ""

    text_blocks = if text in [nil, ""], do: [], else: [%{"type" => "text", "text" => text}]

    tool_blocks =
      Enum.map(tool_calls, fn tc ->
        %{
          "type" => "tool_use",
          "id" => tc[:id] || tc["id"] || "toolu_live",
          "name" => tc[:name] || tc["name"],
          "input" => tc[:arguments] || tc["arguments"] || tc[:input] || tc["input"] || %{}
        }
      end)

    %{
      "id" => "msg_wb_llm_live",
      "type" => "message",
      "role" => "assistant",
      "stop_reason" => if(tool_blocks == [], do: "end_turn", else: "tool_use"),
      "content" => text_blocks ++ tool_blocks
    }
  end

  defp error_message(reason) do
    %{
      "id" => "msg_wb_llm_err",
      "type" => "message",
      "role" => "assistant",
      "stop_reason" => "end_turn",
      "content" => [%{"type" => "text", "text" => "LLM error: #{inspect(reason)}"}]
    }
  end
end
