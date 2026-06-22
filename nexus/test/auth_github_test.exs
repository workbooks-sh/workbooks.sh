defmodule Nexus.Auth.GithubTest do
  use ExUnit.Case, async: true
  import Plug.Test
  alias Nexus.Auth.Github

  test "configured? is a safe boolean (absent secret in test)" do
    assert is_boolean(Github.configured?())
  end

  test "login: 404 when unconfigured, 302 when configured — never crashes" do
    out = Github.login(conn(:get, "/auth/github/login"))
    assert out.status in [302, 404]
  end

  test "callback with no state/code fails closed → 302 to /login with error" do
    out = Github.callback(conn(:get, "/auth/github/callback"))
    assert out.status == 302
    loc = Enum.find_value(out.resp_headers, fn {k, v} -> if k == "location", do: v end)
    assert loc =~ "/login/"
    assert loc =~ "error=github"
  end

  test "callback clears the state cookie on failure" do
    out = Github.callback(conn(:get, "/auth/github/callback"))
    setcookie = Enum.find_value(out.resp_headers, fn {k, v} -> if k == "set-cookie", do: v end)
    assert setcookie =~ "wb_gh_state="
    assert setcookie =~ "max-age=0"
  end
end
