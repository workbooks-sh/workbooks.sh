defmodule Nexus.EmbedTest do
  use ExUnit.Case, async: true

  alias Nexus.Embed

  test "embeds to fixed-dim unit vectors, deterministically" do
    [v] = Embed.embed(["BEAM concurrency"])
    assert length(v) == Nexus.Embed.Hashed.dim()
    norm = :math.sqrt(Enum.reduce(v, 0.0, fn x, a -> a + x * x end))
    assert_in_delta norm, 1.0, 1.0e-6
    assert Embed.embed(["BEAM concurrency"]) == [v]
  end

  test "cosine: related text scores higher than unrelated" do
    q = Embed.embed_one("erlang process scheduling concurrency")
    near = Embed.embed_one("concurrency in the erlang BEAM scheduler")
    far = Embed.embed_one("italian pasta carbonara recipe")
    assert Embed.cosine(q, near) > Embed.cosine(q, far)
  end

  test "empty text → zero vector, cosine safe" do
    z = Embed.embed_one("")
    assert Embed.cosine(z, z) == 0.0
  end

  test "provider seam resolves overrides + default" do
    assert Embed.provider(nil) == Nexus.Embed.Hashed
    assert Embed.provider("hashed") == Nexus.Embed.Hashed
    assert Embed.provider(Nexus.Embed.Hashed) == Nexus.Embed.Hashed
  end
end
