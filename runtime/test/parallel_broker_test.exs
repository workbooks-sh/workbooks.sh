defmodule Workbooks.ParallelBrokerTest do
  use ExUnit.Case, async: false
  alias Workbooks.ParallelBroker

  test "DEFAULT-DENY: map without the grant runs nothing" do
    assert {:error, :denied} = ParallelBroker.map("coreutils", ["a", "b"], argv: ["cat"])
    assert {:error, :denied} = ParallelBroker.map("coreutils", ["a"], allow: false, argv: ["cat"])
  end

  test "fan-out is capped (a guest cannot request unbounded parallel tasks)" do
    huge = for _ <- 1..50, do: "x"
    assert {:error, :too_many_inputs} =
             ParallelBroker.map("coreutils", huge, allow: true, argv: ["cat"], max_inputs: 10)
  end

  test "order-preserving + per-task errors don't sink the batch" do
    # unregistered command -> each task is an ExecBroker deny, but the batch still returns a result list
    assert {:ok, results} = ParallelBroker.map("nope-not-registered", ["a", "b", "c"], allow: true)
    assert length(results) == 3
    assert Enum.all?(results, &match?({:error, _}, &1))
  end

  test "parse_map_request round-trips name+argv+inputs; malformed -> :error" do
    req = build_map_req("coreutils", ["cat"], ["a", "bb", "ccc"])
    assert {:ok, "coreutils", ["cat"], ["a", "bb", "ccc"]} = ParallelBroker.parse_map_request(req)
    assert {:ok, "x", [], []} = ParallelBroker.parse_map_request(build_map_req("x", [], []))
    assert :error = ParallelBroker.parse_map_request(<<>>)
    assert :error = ParallelBroker.parse_map_request(<<5::little-32, "ab">>)
  end

  test "encode_results -> [n][(len, -1=err)(body)]* (binary, order-preserving)" do
    enc = ParallelBroker.encode_results([{:ok, "a"}, {:error, :x}, {:ok, "bb"}])

    assert <<3::little-signed-32, 1::little-signed-32, "a", -1::little-signed-32,
             2::little-signed-32, "bb">> == enc
  end

  defp build_map_req(name, argv, inputs) do
    lp = fn items -> Enum.map_join(items, "", fn i -> <<byte_size(i)::little-32, i::binary>> end) end

    <<byte_size(name)::little-32, name::binary, length(argv)::little-32, lp.(argv)::binary,
      length(inputs)::little-32, lp.(inputs)::binary>>
  end

  @tag :pallet
  @tag timeout: 120_000
  test "DATA-PARALLEL DISPATCH: runs a command over N inputs concurrently in fresh sandboxes" do
    assert :ok = Workbooks.Pallet.seed_one("coreutils")

    # `cat` echoes each task's stdin; results come back in input order (maybe_trim strips trailing \n)
    assert {:ok, results} =
             ParallelBroker.map("coreutils", ["alpha", "beta", "gamma"], allow: true, argv: ["cat"])

    assert results == [{:ok, "alpha"}, {:ok, "beta"}, {:ok, "gamma"}]
  end
end
