defmodule Nexus.Auth.CliTokenTest do
  @moduledoc "POST /auth/token — the headless credential→PAT exchange the `work` CLI uses."
  use ExUnit.Case, async: false
  alias Nexus.Auth.{Native, Accounts}
  alias Nexus.ControlPlane.Token

  setup do
    System.put_env("WB_CONTROL_PLANE", "1")
    on_exit(fn -> System.delete_env("WB_CONTROL_PLANE") end)
    :ok
  end

  defp post(body) do
    Plug.Test.conn(:post, "/auth/token", Jason.encode!(body))
    |> Plug.Conn.put_req_header("content-type", "application/json")
  end

  defp resp(conn), do: Jason.decode!(conn.resp_body)

  test "valid credentials → a minted PAT carrying the user's org + role" do
    email = "cli_#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.create(email, "supersecret", name: "Tester", org: "org_cli", role: "admin")

    conn = Native.token(post(%{email: email, password: "supersecret", name: "my-laptop"}))
    assert conn.status == 200
    body = resp(conn)
    assert body["ok"] and body["org"] == "org_cli"
    assert String.starts_with?(body["token"], "wbk_")

    # The PAT resolves to the user's org with the inherited authority + identity.
    user_id = user.id
    assert {:ok, %{org: "org_cli", role: "admin", user: ^user_id}} = Token.resolve(body["token"])
  end

  test "wrong password → 401, no token" do
    email = "cli_#{System.unique_integer([:positive])}@example.com"
    {:ok, _} = Accounts.create(email, "supersecret", org: "org_cli2")

    conn = Native.token(post(%{email: email, password: "nope"}))
    assert conn.status == 401
    refute resp(conn)["token"]
  end

  test "not a control-plane nexus → 404 (this nexus does not issue CLI tokens)" do
    System.delete_env("WB_CONTROL_PLANE")
    conn = Native.token(post(%{email: "x@example.com", password: "y"}))
    assert conn.status == 404
  end
end
