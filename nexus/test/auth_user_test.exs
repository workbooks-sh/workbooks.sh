defmodule Nexus.AuthUserTest do
  @moduledoc """
  Tests for wb-q7w5: the authenticated uid must reach server route handlers as `req.user`, so
  server.work `user_key`/`profile_uid` can prefer the REAL session uid over a spoofable body/query
  `u`. `Nexus.Auth.user/1` (the server-derived uid, mirror of `role/1`) is the lib seam.

  The RED test is the end-to-end one: `Nexus.Server`'s `try_route` (server.ex:810-826) builds the
  handler `req` with server-derived `tenant` + `role` but TODAY DROPS the user — so a handler cannot
  tell who is authenticated and falls back to a client-supplied `u`. After the fix the req carries
  `user: Nexus.Auth.user(conn)`. We prove it by configuring a test auth adapter that fixes the
  identity's user, registering an echo route, and asserting the handler saw `req.user`.
  """
  use ExUnit.Case, async: false
  import Plug.Conn
  alias Nexus.Auth

  # ── lib seam (already present): Auth.user/1 reads the server-set identity, never the client ──────

  test "Auth.user/1 returns identity[:user] or nil — never a client value" do
    authed = Plug.Test.conn(:get, "/") |> assign(:identity, %{tenant: "acme", user: "alice@example.com"})
    assert Auth.user(authed) == "alice@example.com"

    none = Plug.Test.conn(:get, "/") |> assign(:identity, %{tenant: "default", user: nil})
    assert Auth.user(none) == nil

    assert Auth.user(Plug.Test.conn(:get, "/")) == nil
  end

  # ── RED: try_route must thread `user:` into the handler req ──────────────────────────────────────

  defmodule FixedUserAuth do
    @moduledoc false
    @behaviour Nexus.Auth
    @impl true
    def authenticate(_conn),
      do: {:ok, %{tenant: "acme", user: "alice@example.com", roles: ["member"]}}
  end

  defmodule Echo do
    use Nexus.Router
    route("GET /api/whoami", :whoami)
    # echo the server-derived identity fields the handler is allowed to trust
    def whoami(req), do: %{user: Map.get(req, :user), tenant: req.tenant, role: req.role}
  end

  setup do
    prev = Application.get_env(:nexus, :auth)
    Application.put_env(:nexus, :auth, FixedUserAuth)
    Nexus.Router.install(Echo)
    port = 4597
    start_supervised!({Nexus.Server, root: File.cwd!(), port: port})
    :inets.start()

    on_exit(fn ->
      if prev, do: Application.put_env(:nexus, :auth, prev), else: Application.delete_env(:nexus, :auth)
    end)

    {:ok, port: port}
  end

  defp get(port, path) do
    {:ok, {{_, code, _}, _h, body}} =
      :httpc.request(:get, {~c"http://127.0.0.1:#{port}#{path}", []}, [], body_format: :binary)

    {code, Jason.decode!(body)}
  end

  test "try_route threads the authenticated user into req.user (handler sees it)", %{port: port} do
    {200, body} = get(port, "/api/whoami")
    assert body["tenant"] == "acme"
    assert body["role"] == "member"
    # THE BUG: today req has no :user, so this is nil. After the fix it equals the session uid.
    assert body["user"] == "alice@example.com"
  end
end
