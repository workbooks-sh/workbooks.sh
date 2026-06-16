defmodule Workbooks.AgentPromptTest do
  @moduledoc """
  Pins Waldo's COMPOSED system prompt (web.ex agent_system_prompt) — its
  foundation: base persona + the toolkit index. A composition regression (e.g.
  the toolkit injection silently dropping, or the default toolkit set changing)
  would strip Waldo's capabilities without any other test noticing. Routed
  through the real GET /api/agents/:slug/system_prompt endpoint.
  """
  use ExUnit.Case, async: false
  import Plug.Test

  # Pin the default in-tree toolkit root (wb-q2qg): WB_WORKKITS_ROOT is global env
  # and several other tests point it at temp fixture dirs (lacking the real skills).
  # A leaked/overlapping value made this test flake — the index would compose from
  # a fixture root missing variables/library-search. Force the real root here.
  setup do
    prev = System.get_env("WB_WORKKITS_ROOT")
    System.delete_env("WB_WORKKITS_ROOT")
    on_exit(fn -> if prev, do: System.put_env("WB_WORKKITS_ROOT", prev), else: System.delete_env("WB_WORKKITS_ROOT") end)
    :ok
  end

  defp prompt(slug) do
    conn = Workbooks.Web.call(conn(:get, "/api/agents/#{slug}/system_prompt"), Workbooks.Web.init([]))
    assert conn.status == 200
    Jason.decode!(conn.resp_body)["system_prompt"]
  end

  test "Waldo's prompt has the persona + reply-style guidance" do
    p = prompt("waldo")
    assert p =~ "Waldo"
    assert p =~ "resident assistant"
    # works WITH the user, never runs off (the brand rule)
    assert p =~ ~r/never run off|work problems WITH/i
    # streaming-prose reply style + the optional org/component rich-reply path
    assert p =~ "RICH REPLIES" or p =~ "#+RENDER"
  end

  test "Waldo's prompt composes the toolkit index with BOTH default toolkits" do
    p = prompt("waldo")
    assert p =~ "## Toolkits"
    assert p =~ "workbooks-browser"
    assert p =~ "workbooks-cli"
    # the progressive-disclosure instruction (read a skill on demand)
    assert p =~ "toolkit show"
    # representative skill slugs from each toolkit are listed in the index
    assert p =~ "variables" or p =~ "library-search"
    assert p =~ "deploy" or p =~ "publish"
  end

  test "an unknown slug still gets the safe default prompt (voice/chat works out of the box)" do
    p = prompt("some-unprovisioned-agent")
    assert p =~ "Waldo"
    assert p =~ "## Toolkits"
  end
end
