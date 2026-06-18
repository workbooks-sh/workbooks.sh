defmodule Nexus.ConfigTest do
  use ExUnit.Case, async: false

  test "defaults when there is no <work-deploy> config" do
    Nexus.Config.reload(nil)
    assert Nexus.Config.compile_concurrency() == System.schedulers_online()
    assert Nexus.Config.compile_cache?() == true
    assert Nexus.Config.compile_cache_version() == "wbc1"
    assert Nexus.Config.languages() == :all
    assert Nexus.Config.pm_debug?() == false
  after
    Nexus.Config.reload(nil)
  end

  test "knobs are read from the <work-deploy> element (HTML source of truth, not env)" do
    html = ~s(<html><body><work-deploy engine-place="cloud"
      compile-concurrency="3" compile-cache="off" compile-cache-version="v7"
      component-cache="r2://my-bucket/components" languages="rust zig" pm-debug="on"></work-deploy></body></html>)
    Nexus.Config.reload(html)
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
