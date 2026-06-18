defmodule WorkCore.DeployConfigTest do
  use ExUnit.Case, async: true
  alias WorkCore.DeployConfig

  test "scaffold → parse round-trips into uppercase property keys" do
    {:ok, p} = DeployConfig.scaffold("local") |> DeployConfig.parse()
    assert p["ENGINE_PLACE"] == "local"
    assert p["DATABASE"] == "sqlite"
    assert p["AUTH"] == "trusted"
    assert DeployConfig.place(p) == "local"
  end

  test "a coherent local config validates clean" do
    {:ok, p} = DeployConfig.scaffold("local") |> DeployConfig.parse()
    assert DeployConfig.validate(p) == :ok
  end

  test "validate catches the open-control-plane + tenancy/auth + backend mismatches" do
    html = ~s(<work-deploy engine-place="cloud" tenancy-mode="multi" storage="s3" database="postgres" auth="trusted">)
    {:ok, p} = DeployConfig.parse(html)
    assert {:error, issues} = DeployConfig.validate(p)
    assert Enum.any?(issues, &(&1 =~ "OPEN control plane"))
    assert Enum.any?(issues, &(&1 =~ "multi needs real AUTH"))
    assert Enum.any?(issues, &(&1 =~ "s3 needs"))
  end

  test "validate rejects an unknown enum value" do
    {:ok, p} = DeployConfig.parse(~s(<work-deploy engine-place="local" database="mongo">))
    assert {:error, issues} = DeployConfig.validate(p)
    assert Enum.any?(issues, &(&1 =~ "DATABASE"))
  end

  test "parse errors when there is no <work-deploy> element" do
    assert {:error, :no_work_deploy_element} = DeployConfig.parse("<html>nope</html>")
  end
end
