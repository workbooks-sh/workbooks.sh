defmodule Workbooks.CappedHttpTest do
  use ExUnit.Case, async: false
  alias Workbooks.CappedHttp

  setup_all do
    Application.ensure_all_started(:inets)
    :ok
  end

  @tag :netdeps
  test "caps the response body — a response larger than max_bytes is rejected (host never over-buffers)" do
    # httpbin returns 6000 bytes; a 5000-byte cap must reject it BEFORE buffering it all
    url = ~c"http://httpbin.org/bytes/6000"
    assert {:error, :too_large} = CappedHttp.get(url, [], [{:timeout, 12_000}], 5_000, 12_000)
  end

  @tag :netdeps
  test "passes a response within the cap, returning headers + the full body" do
    url = ~c"http://httpbin.org/bytes/3000"
    assert {:ok, headers, body} = CappedHttp.get(url, [], [{:timeout, 12_000}], 1_000_000, 12_000)
    assert byte_size(body) == 3000
    assert is_list(headers)
  end

  @tag :netdeps
  test "the wall-clock deadline bounds a slow response (slowloris floor)" do
    # a 1ms deadline against a real fetch trips the timeout (the absolute deadline can't be reset by drips)
    url = ~c"http://httpbin.org/delay/3"
    assert {:error, reason} = CappedHttp.get(url, [], [{:timeout, 12_000}], 1_000_000, 1)
    assert reason in [:timeout, :request_failed]
  end
end
