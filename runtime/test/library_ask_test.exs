defmodule Workbooks.LibraryAskTest do
  @moduledoc """
  Pins the AI-over-files endpoint (POST /api/library/ask, wb-ndlz) HONESTY: when the
  tenant's library has nothing matching, the answer is an honest "couldn't find it"
  with NO fabricated sources — the runtime never invents files or facts. Deterministic:
  the empty path returns before any LLM call. Uses a FRESH tenant so the library is
  guaranteed empty regardless of test order.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  defp ask(query) do
    tenant = "libask-#{System.unique_integer([:positive])}"

    conn =
      conn(:post, "/api/library/ask", Jason.encode!(%{query: query}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-tenant", tenant)
      |> Workbooks.Web.call(Workbooks.Web.init([]))

    {conn.status, Jason.decode!(conn.resp_body)}
  end

  test "empty library → honest no-fabricate answer (no invented sources)" do
    {status, body} = ask("what does my Q3 roadmap say about hiring plans")
    assert status == 200
    assert body["sources"] == []
    assert body["related"] == []
    assert body["answer"] =~ "couldn't find" or body["answer"] =~ "Nothing in your library"
  end

  test "blank query → empty result, no search, no fabrication" do
    {status, body} = ask("")
    assert status == 200
    assert body["sources"] == []
  end
end
