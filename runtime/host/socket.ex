defmodule Workbooks.Socket do
  @moduledoc """
  The live bridge: a served Workbook page talks to its Instance / the kernel over
  a WebSocket, not just fetch. Each text frame is `{"fn": ..., "org": ...}`; the
  reply is the JSON result. This is the interactive upgrade over the HTTP backend
  in web.ex — same dispatch, streamed.
  """
  @behaviour WebSock

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_in({text, [opcode: :text]}, state) do
    reply =
      case Jason.decode(text) do
        {:ok, %{"fn" => fun, "org" => org}} -> Jason.encode!(dispatch(fun, org))
        _ -> ~s({"error":"expected {fn, org}"})
      end

    {:push, {:text, reply}, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok

  defp dispatch("parse", org), do: Workbooks.Workbook.parse_headlines(org)
  defp dispatch("tangle", org), do: Workbooks.Workbook.tangle_plan(org)
  defp dispatch("validate", org), do: Workbooks.Workbook.validate(org)
  defp dispatch("render", org), do: %{"html" => org}
  defp dispatch(_, _), do: %{"error" => "unknown fn"}
end
