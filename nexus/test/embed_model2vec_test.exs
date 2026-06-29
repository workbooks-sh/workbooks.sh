defmodule Nexus.Embed.Model2VecTest do
  use ExUnit.Case, async: false

  alias Nexus.Embed
  alias Nexus.Embed.Model2Vec

  setup do
    on_exit(&Model2Vec.reset/0)
    :ok
  end

  test "provider/1 resolves \"model2vec\" to the module" do
    assert Embed.provider("model2vec") == Model2Vec
  end

  test "falls back to Hashed (256-dim, valid) when no table is configured" do
    Model2Vec.reset()
    [v] = Model2Vec.embed(["rebase a branch"])
    assert length(v) == 256
    assert Enum.all?(v, &is_float/1)
  end

  describe "with a distilled table loaded" do
    setup do
      # tiny synthetic table: 4-dim near-orthogonal unit vectors per token
      vectors = %{
        "git" => unit([1.0, 0.0, 0.0, 0.0]),
        "rebase" => unit([0.0, 1.0, 0.0, 0.0]),
        "merge" => unit([0.0, 0.0, 1.0, 0.0]),
        "undo" => unit([0.0, 0.0, 0.0, 1.0])
      }

      Model2Vec.load(%{dim: 4, vectors: vectors, weights: nil})
      :ok
    end

    test "dim reflects the table; vectors are table-dim and L2-normalized" do
      assert Model2Vec.dim() == 4
      [v] = Model2Vec.embed(["git rebase"])
      assert length(v) == 4
      assert_in_delta mag(v), 1.0, 1.0e-6
    end

    test "mean-pools tokens — shared-token texts are more similar than disjoint ones" do
      [a] = Model2Vec.embed(["git rebase"])
      [b] = Model2Vec.embed(["git merge"])
      [c] = Model2Vec.embed(["undo"])
      assert Embed.cosine(a, b) > Embed.cosine(a, c)
    end

    test "OOV tokens back off to a deterministic sub-vector (no crash, still signal)" do
      [v1] = Model2Vec.embed(["totallyunknownword"])
      [v2] = Model2Vec.embed(["totallyunknownword"])
      assert length(v1) == 4
      assert v1 == v2
    end

    test "routes through Nexus.Embed with provider override" do
      v = Embed.embed_one("git rebase", provider: "model2vec")
      assert length(v) == 4
    end
  end

  defp unit(v), do: (n = mag(v)) && Enum.map(v, &(&1 / n))
  defp mag(v), do: v |> Enum.reduce(0.0, fn x, a -> a + x * x end) |> :math.sqrt()
end
