defmodule Nexus.Store.CodecTest do
  use ExUnit.Case, async: true

  alias Nexus.Store.Codec

  describe "round-trip" do
    test "persisted structs/scalars/maps/lists/atoms decode exactly" do
      for term <- [
            %{a: 1, b: "two", c: [:x, :y, 3]},
            {:ok, "tuple"},
            [1, 2, 3, :enum_atom],
            "a binary",
            :a_bare_atom,
            %{nested: %{deep: [%{k: :v}]}}
          ] do
        assert Codec.decode(Codec.encode(term)) == term
      end
    end
  end

  describe "safe sink refuses executable gadgets" do
    test "a blob carrying an anonymous function raises (does not detonate)" do
      gadget = :erlang.term_to_binary(fn -> :pwned end)
      assert_raise ArgumentError, fn -> Codec.decode(gadget) end
    end

    test "garbage bytes raise rather than crash silently" do
      assert_raise ArgumentError, fn -> Codec.decode(<<0, 1, 2, 3, 255>>) end
    end
  end

  describe "decode_rows quarantines poison instead of crashing the whole read" do
    test "one poisoned row is dropped, clean rows survive" do
      good1 = Codec.encode(%{id: 1})
      good2 = Codec.encode(%{id: 2})
      poison = :erlang.term_to_binary(fn -> :rce end)
      garbage = <<13, 37, 0, 255>>

      result = Codec.decode_rows([[good1], [poison], [good2], [garbage]], op: :test)

      assert result == [%{id: 1}, %{id: 2}]
    end

    test "fuzz: arbitrary non-executable terms always round-trip; never raises out of decode_rows" do
      for _ <- 1..200 do
        term = rand_term(0)
        [decoded] = Codec.decode_rows([[Codec.encode(term)]], op: :fuzz)
        assert decoded == term
      end
    end
  end

  # small recursive generator of safe terms (no funs/pids/ports/refs)
  defp rand_term(depth) when depth > 3, do: Enum.random([1, "s", :atom, 3.5])

  defp rand_term(depth) do
    case Enum.random(0..6) do
      0 -> Enum.random(-1000..1000)
      1 -> for _ <- 1..Enum.random(0..4)//1, into: "", do: <<Enum.random(?a..?z)>>
      2 -> Enum.random([:a, :b, :c, :ok, :error])
      3 -> for _ <- 1..Enum.random(0..3)//1, do: rand_term(depth + 1)
      4 -> {rand_term(depth + 1), rand_term(depth + 1)}
      5 -> %{Enum.random([:x, :y, :z]) => rand_term(depth + 1)}
      6 -> Enum.random([0.0, 1.5, -2.25])
    end
  end
end
