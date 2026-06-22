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

defmodule Nexus.Auth.GithubProxyTest do
  # Pins the proxy-scheme fix: behind a TLS-terminating proxy the redirect_uri MUST be https, or GitHub
  # rejects it. async: false because it sets process-wide env.
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn, only: [put_req_header: 3]
  alias Nexus.Auth.Github

  setup do
    System.put_env("GITHUB_APP_CLIENT_ID", "Iv_test")
    System.put_env("GITHUB_APP_CLIENT_SECRET", "shh")
    on_exit(fn -> System.delete_env("GITHUB_APP_CLIENT_ID"); System.delete_env("GITHUB_APP_CLIENT_SECRET") end)
    :ok
  end

  test "x-forwarded-proto=https → the redirect_uri is https (not the proxy-local http)" do
    assert Github.configured?()

    loc =
      conn(:get, "/auth/github/login")
      |> put_req_header("x-forwarded-proto", "https")
      |> put_req_header("x-forwarded-host", "wb-dogfood.fly.dev")
      |> Github.login()
      |> then(fn out -> Enum.find_value(out.resp_headers, fn {k, v} -> if k == "location", do: v end) end)

    assert loc =~ "redirect_uri=https%3A%2F%2Fwb-dogfood.fly.dev%2Fauth%2Fgithub%2Fcallback"
    refute loc =~ "redirect_uri=http%3A%2F"
  end
end
