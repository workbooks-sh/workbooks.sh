defmodule Nexus.DeployCloudTest do
  use ExUnit.Case, async: false

  setup do
    on_exit(fn -> System.delete_env("WB_ALLOW_CP_DEPLOY") end)
    :ok
  end

  test "cloud_args builds the fly deploy command against the control-plane config" do
    args = Nexus.Deploy.cloud_args()
    assert args == ["deploy", "--config", "nexus/deploy/control-plane/fly.toml", "--app", "wb-nexus-cp"]

    pinned = Nexus.Deploy.cloud_args(app: "cp2", image: "ghcr.io/x@sha256:abc", remote_only: true)
    assert pinned == ["deploy", "--config", "nexus/deploy/control-plane/fly.toml", "--app", "cp2",
                      "--image", "ghcr.io/x@sha256:abc", "--remote-only"]
  end

  test "cloud is GUARDED — refuses to deploy without WB_ALLOW_CP_DEPLOY (accidental call is a no-op)" do
    System.delete_env("WB_ALLOW_CP_DEPLOY")
    assert Nexus.Deploy.cloud() == {:error, :deploy_guarded}
  end
end
