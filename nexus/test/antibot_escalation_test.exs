defmodule Nexus.AntibotEscalationTest do
  use ExUnit.Case, async: true

  # The curl-impersonate fallback DECISION logic — pure, no network, no binary required.
  # (The network retry itself depends on a blocked site + the impersonate binary being present;
  #  this covers the escalation gate without either.)
  alias Nexus.Compilers.Shared

  @real_200 String.duplicate("<p>real article paragraph with lots of content</p>\n", 50)

  test "a real, populated 200 does NOT escalate (fast path stays fast)" do
    refute Shared.should_escalate?(200, @real_200)
  end

  test "a 403 escalates (Chrome TLS fingerprint tier)" do
    assert Shared.should_escalate?(403, "Forbidden")
  end

  test "challenge statuses escalate regardless of body" do
    for code <- [401, 403, 406, 429, 503] do
      assert Shared.should_escalate?(code, @real_200), "expected #{code} to escalate"
    end
  end

  test "a 200 with a suspiciously tiny body escalates" do
    assert Shared.should_escalate?(200, "<html></html>")
  end

  test "a 200 CF-challenge interstitial body escalates even when not tiny" do
    body = "<html><head><title>Just a moment...</title></head><body>" <>
             String.duplicate("checking your browser before accessing. ", 30) <>
             "challenge-platform</body></html>"
    assert Shared.should_escalate?(200, body)
  end

  test "a non-binary body falls back to status-only decision" do
    assert Shared.should_escalate?(403, nil)
    refute Shared.should_escalate?(200, nil)
  end

  test "binary discovery returns nil when nothing is configured/on PATH (graceful degrade)" do
    # No :nexus, :curl_impersonate configured and the curl_chrome* wrappers aren't installed here.
    assert is_nil(Shared.curl_impersonate_bin()) or is_binary(Shared.curl_impersonate_bin())
  end
end
