#!/usr/bin/env elixir
# A minimal FAKE ACP agent for the desktop-broker hermetic tests — NO real claude/codex,
# no network, no LLM. It speaks just enough Agent Client Protocol over stdio to drive one
# full turn against Workbooks.DesktopAgent:
#
#   initialize        -> reply {protocolVersion, authMethods: []}   (no auth needed)
#   session/new       -> reply {sessionId: "fake-sess-1"}
#   session/prompt    -> emit a `tool_call` + `tool_call_update(completed)` session/update,
#                        an `agent_message_chunk` echoing the prompt text, a `usage_update`,
#                        then reply {stopReason: "end_turn"}.
#
# Each JSON-RPC message is one line on stdin/stdout (the broker uses {:line, _} framing).
# Reads are line-buffered; we never block on more than one line of look-ahead.

defmodule FakeAcpAgent do
  def main do
    loop()
  end

  defp loop do
    case IO.gets("") do
      :eof ->
        :ok

      {:error, _} ->
        :ok

      line ->
        line = String.trim(line)

        if line != "" do
          case safe_decode(line) do
            {:ok, msg} -> handle(msg)
            _ -> :ok
          end
        end

        loop()
    end
  end

  # ── requests from the client (the broker) ──────────────────────────────────

  defp handle(%{"id" => id, "method" => "initialize"}) do
    reply(id, %{"protocolVersion" => 1, "authMethods" => []})
  end

  defp handle(%{"id" => id, "method" => "session/new"}) do
    reply(id, %{"sessionId" => "fake-sess-1"})
  end

  defp handle(%{"id" => id, "method" => "session/prompt", "params" => params}) do
    sid = params["sessionId"]
    text = prompt_text(params["prompt"])

    # A tool call, opened then completed → two session/update notifications. The broker maps
    # these into telemetry step records (tool_call opens, tool_call_update closes + emits).
    notify("session/update", %{
      "sessionId" => sid,
      "update" => %{
        "sessionUpdate" => "tool_call",
        "toolCallId" => "tc-1",
        "kind" => "read",
        "title" => "read file",
        "rawInput" => %{"path" => "README.md"}
      }
    })

    notify("session/update", %{
      "sessionId" => sid,
      "update" => %{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => "tc-1",
        "status" => "completed",
        "content" => [%{"type" => "content", "content" => %{"type" => "text", "text" => "file body"}}]
      }
    })

    # An assistant message chunk → harvested into the structured `output`.
    notify("session/update", %{
      "sessionId" => sid,
      "update" => %{
        "sessionUpdate" => "agent_message_chunk",
        "content" => %{"type" => "text", "text" => "echo:" <> text}
      }
    })

    notify("session/update", %{
      "sessionId" => sid,
      "update" => %{"sessionUpdate" => "usage_update", "used" => 42, "size" => 1000}
    })

    reply(id, %{"stopReason" => "end_turn"})
  end

  # Unknown method with an id → method-not-found (fail-closed parity, never hangs the client).
  defp handle(%{"id" => id, "method" => _other}) do
    error(id, -32601, "method_not_found")
  end

  # Notifications (no id) — ignore.
  defp handle(_), do: :ok

  defp prompt_text(blocks) when is_list(blocks) do
    blocks
    |> Enum.map(fn
      %{"text" => t} -> t
      _ -> ""
    end)
    |> Enum.join("")
  end

  defp prompt_text(_), do: ""

  # ── JSON-RPC writers (one line each, flushed) ──────────────────────────────

  defp reply(id, result),
    do: emit(%{"jsonrpc" => "2.0", "id" => id, "result" => result})

  defp error(id, code, message),
    do: emit(%{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}})

  defp notify(method, params),
    do: emit(%{"jsonrpc" => "2.0", "method" => method, "params" => params})

  defp emit(msg) do
    IO.write([:json.encode(msg), "\n"])
  end

  # Standalone `elixir` scripts have no Jason; OTP 27+ ships :json. Decode a single JSON line.
  defp safe_decode(line) do
    {:ok, :json.decode(line)}
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end
end

FakeAcpAgent.main()
