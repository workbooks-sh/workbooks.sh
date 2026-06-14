defmodule Workbooks.NetGuardCapTest do
  @moduledoc """
  Pins the wb-j3n8 body cap: NetGuard.get truncates the body it HOLDS/returns to
  max_bytes (parity with request/3) so a large/hostile upstream can't balloon host
  memory. (Peak receive RAM is the separate streaming cap, wb-4had.) Deterministic.
  """
  use ExUnit.Case, async: true
  alias Workbooks.NetGuard

  test "an over-cap body is truncated to max_bytes" do
    assert NetGuard.cap_body_for_test("hello world", 5) == "hello"
    assert byte_size(NetGuard.cap_body_for_test(:binary.copy("x", 100), 32)) == 32
  end

  test "an under-cap body is returned unchanged" do
    assert NetGuard.cap_body_for_test("hi", 5) == "hi"
    assert NetGuard.cap_body_for_test("", 5) == ""
  end

  test "a non-binary body passes through (defensive)" do
    assert NetGuard.cap_body_for_test(nil, 5) == nil
  end
end
