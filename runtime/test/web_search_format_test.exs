defmodule Workbooks.WebSearchFormatTest do
  @moduledoc """
  Pins the web_search result formatter — esp. the AMBIGUOUS-empty message: an empty
  result must signal it MIGHT be backend-unavailable (not just 'nothing matched'),
  so the agent doesn't mislabel a search failure as 'the topic is empty' (the 6h
  lander mislabel the file_issue seam exists to prevent). Deterministic.
  """
  use ExUnit.Case, async: true
  alias Workbooks.Agent

  test "empty results explain the ambiguity (no false 'topic is empty')" do
    out = Agent.format_search_results_for_test([])
    assert out =~ "unavailable"
    refute out == "no results"
  end

  test "hits render as title + url + snippet bullets" do
    hits = [%{title: "Auth headers", url: "https://x/a", snippet: "how to handle auth"},
            %{title: "No snippet", url: "https://x/b"}]
    out = Agent.format_search_results_for_test(hits)
    assert out =~ "• Auth headers"
    assert out =~ "https://x/a"
    assert out =~ "how to handle auth"
    assert out =~ "• No snippet"
  end
end
