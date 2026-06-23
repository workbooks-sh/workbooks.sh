defmodule Nexus.ArtifactTrustTest do
  @moduledoc "Seam 0.4 / wb-skhj/wb-b2ow: image refs resolve through the supply-chain trust seam."
  use ExUnit.Case, async: false

  alias Nexus.ArtifactTrust

  # drive the policy by setting the persistent_term config map directly (no deploy-block needed)
  defp put_policy(registries, pins) do
    cur = (:persistent_term.get({Nexus.Config, :cfg}, nil) || %{})
    base = if map_size(cur) == 0, do: %{runtime_image: "x"}, else: cur
    :persistent_term.put({Nexus.Config, :cfg}, Map.merge(base, %{image_registries: registries, image_pins: pins}))
    on_exit(fn -> :persistent_term.put({Nexus.Config, :cfg}, cur) end)
  end

  test "neutral default (no allowlist) is permissive" do
    put_policy([], %{})
    assert {:ok, "ghcr.io/anyone/whatever:latest"} = ArtifactTrust.resolve("ghcr.io/anyone/whatever:latest")
  end

  test "a ref outside the allowlist is refused (fail closed)" do
    put_policy(["ghcr.io/workbooks-sh/"], %{})
    assert {:error, :untrusted_registry} = ArtifactTrust.resolve("ghcr.io/evil/backdoor:latest")
    assert {:ok, _} = ArtifactTrust.resolve("ghcr.io/workbooks-sh/runtime:latest")
  end

  test "a pinned repo is rewritten to its content digest (mutable tag dropped)" do
    put_policy([], %{"ghcr.io/workbooks-sh/runtime" => "sha256:abc123"})
    assert {:ok, "ghcr.io/workbooks-sh/runtime@sha256:abc123"} =
             ArtifactTrust.resolve("ghcr.io/workbooks-sh/runtime:latest")
  end

  test "resolve! raises on an untrusted ref" do
    put_policy(["ghcr.io/workbooks-sh/"], %{})
    assert_raise ArgumentError, fn -> ArtifactTrust.resolve!("docker.io/evil/x:latest") end
  end

  test "empty/blank ref is refused" do
    put_policy([], %{})
    assert {:error, :no_image} = ArtifactTrust.resolve("")
  end

  test "registry host:port is not mistaken for a tag" do
    put_policy([], %{"localhost:5000/runtime" => "sha256:def"})
    assert {:ok, "localhost:5000/runtime@sha256:def"} = ArtifactTrust.resolve("localhost:5000/runtime:v1")
  end
end
