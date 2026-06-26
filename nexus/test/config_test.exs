defmodule Nexus.ConfigTest do
  use ExUnit.Case, async: false

  test "washy per-run bounds: neutral defaults, deploy-tunable" do
    Nexus.Config.reload(nil)
    assert Nexus.Config.washy_fuel() == 2_000_000_000
    assert Nexus.Config.washy_timeout_ms() == 30_000
    assert Nexus.Config.washy_max_output() == 16 * 1024 * 1024
    assert Keyword.fetch!(Nexus.Config.washy_limits(), :max_depth) == 10_000

    src = ~s(deploy do\n  washy-fuel="5000000" washy-timeout-ms="8000" washy-max-output-mb="4" washy-max-pages="256"\nend\n)
    Nexus.Config.reload(src)
    assert Nexus.Config.washy_fuel() == 5_000_000
    assert Nexus.Config.washy_timeout_ms() == 8_000
    assert Nexus.Config.washy_max_output() == 4 * 1024 * 1024
    assert Nexus.Config.washy_max_pages() == 256
  after
    Nexus.Config.reload(nil)
  end

  test "dashboard cutover flag: defaults legacy, deploy-flips to studio" do
    Nexus.Config.reload(nil)
    assert Nexus.Config.dashboard() == "legacy"
    refute Nexus.Config.studio_dashboard?()

    Nexus.Config.reload(~s(deploy do\n  dashboard="studio"\nend\n))
    assert Nexus.Config.dashboard() == "studio"
    assert Nexus.Config.studio_dashboard?()
  after
    Nexus.Config.reload(nil)
  end

  test "defaults when there is no deploy config" do
    Nexus.Config.reload(nil)
    assert Nexus.Config.compile_concurrency() == System.schedulers_online()
    assert Nexus.Config.compile_cache?() == true
    assert Nexus.Config.compile_cache_version() == "wbc1"
    assert Nexus.Config.languages() == :all
    assert Nexus.Config.pm_debug?() == false
  after
    Nexus.Config.reload(nil)
  end

  test "knobs are read from the .work deploy block (source of truth, not env)" do
    src = ~s(# Deployment\n\ndeploy do\n  engine-place="cloud"\n  compile-concurrency="3" compile-cache="off" compile-cache-version="v7"\n  component-cache="r2://my-bucket/components" languages="rust zig" pm-debug="on"\nend\n)
    Nexus.Config.reload(src)
    assert Nexus.Config.compile_concurrency() == 3
    assert Nexus.Config.compile_cache?() == false
    assert Nexus.Config.compile_cache_version() == "v7"
    assert Nexus.Config.component_cache() == "r2://my-bucket/components"
    assert Nexus.Config.languages() == ["rust", "zig"]
    assert Nexus.Config.pm_debug?() == true
  after
    Nexus.Config.reload(nil)
  end

  test "env vars do NOT configure these knobs anymore" do
    System.put_env("WB_COMPILE_CONCURRENCY", "99")
    Nexus.Config.reload(nil)
    assert Nexus.Config.compile_concurrency() == System.schedulers_online()
    refute Nexus.Config.compile_concurrency() == 99
  after
    System.delete_env("WB_COMPILE_CONCURRENCY")
    Nexus.Config.reload(nil)
  end
end
