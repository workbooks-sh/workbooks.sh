defmodule Workbooks.HtmlToTextTest do
  @moduledoc """
  Pins the fetch tool's HTML→text extraction (what the agent gets when it pulls a
  page). Regression target: the old `&[a-z]+;`→space mangled entities + left numeric
  entities as literal junk. Now: proper decode + script/style/nav/footer chrome
  dropped. Deterministic.
  """
  use ExUnit.Case, async: true
  alias Workbooks.Agent

  test "decodes named + numeric entities (no more mangled apostrophes/ampersands)" do
    out = Agent.html_to_text_for_test(~s|<p>Tom&#39;s &amp; Jerry&#39;s &quot;cafe&quot;</p>|)
    assert out =~ "Tom's"
    assert out =~ "&"
    assert out =~ ~s|"cafe"|
    refute out =~ "&#39;"
    refute out =~ "&amp;"
  end

  test "drops script/style/nav/footer chrome, keeps article text" do
    html = ~s|<nav>Home About</nav><script>track()</script><article>The real content here.</article><footer>copyright 2026 links</footer>|
    out = Agent.html_to_text_for_test(html)
    assert out =~ "The real content here."
    refute out =~ "track()"
    refute out =~ "Home About"
    refute out =~ "2026 links"
  end

  test "strips tags + collapses whitespace" do
    assert Agent.html_to_text_for_test("<h1>Hi</h1>\n\n  <p>there</p>") == "Hi there"
  end
end
