defmodule Nexus.Embed.GatewayTest do
  use ExUnit.Case, async: true

  alias Nexus.Embed
  alias Nexus.Embed.Gateway

  test "provider/1 resolves the gateway aliases" do
    assert Embed.provider("nomic") == Gateway
    assert Embed.provider("cf-bge") == Gateway
    assert Embed.provider("gateway") == Gateway
  end

  test "build_body is the OpenAI-compatible embeddings shape" do
    assert Gateway.build_body("nomic-embed-text-v1.5", ["a", "b"]) ==
             %{model: "nomic-embed-text-v1.5", input: ["a", "b"]}
  end

  test "parse_embeddings normalizes vectors and respects index order" do
    decoded = %{
      "data" => [
        %{"index" => 1, "embedding" => [0.0, 3.0, 4.0]},
        %{"index" => 0, "embedding" => [3.0, 4.0, 0.0]}
      ]
    }

    [v0, v1] = Gateway.parse_embeddings(decoded, 2)
    # reordered by :index, each L2-normalized (magnitude 1)
    assert_in_delta mag(v0), 1.0, 1.0e-9
    assert_in_delta mag(v1), 1.0, 1.0e-9
    assert_in_delta Enum.at(v0, 0), 0.6, 1.0e-9
  end

  test "parse_embeddings degrades gracefully on a malformed payload" do
    assert Gateway.parse_embeddings(%{}, 3) == [[], [], []]
  end

  test "embed/1 falls back to Hashed (256-dim) when the gateway is unconfigured" do
    # no CF_AIG_URL / account secret in test → :unconfigured → Hashed
    [v] = Gateway.embed(["rebase a branch"])
    assert length(v) == 256
    assert Enum.all?(v, &is_float/1)
  end

  defp mag(v), do: v |> Enum.reduce(0.0, fn x, a -> a + x * x end) |> :math.sqrt()
end
