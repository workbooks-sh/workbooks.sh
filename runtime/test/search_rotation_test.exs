defmodule Workbooks.SearchRotationTest do
  @moduledoc """
  Pins engine rotation: with no forced engine, query rotates across ALL providers
  (spread load, avoid hammering one into 429); a forced :engine bypasses rotation.
  Proxy/IP rotation is a future cloud add-on — this is the no-infra cheap win.
  """
  use ExUnit.Case, async: true
  alias Workbooks.Browse.Search

  test "rotation includes every provider (order varies, set is stable)" do
    assert Enum.sort(Search.engines_for_test(nil)) == [:bing, :brave, :duckduckgo]
    # shuffled — over several draws we should see more than one starting engine
    firsts = for _ <- 1..30, do: hd(Search.engines_for_test(nil))
    assert length(Enum.uniq(firsts)) > 1, "rotation should not always start with the same engine"
  end

  test "a forced engine bypasses rotation" do
    assert Search.engines_for_test(:brave) == [:brave]
  end
end
