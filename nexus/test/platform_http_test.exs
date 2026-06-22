defmodule Nexus.PlatformHttpTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @opts Nexus.Platform.init([])

  defp call(method, path, org, body \\ nil) do
    c =
      if body do
        conn(method, path, Jason.encode!(body)) |> put_req_header("content-type", "application/json")
      else
        conn(method, path)
      end

    # Assign a full identity (owner role) so these org-scoping tests exercise cross-org isolation, not
    # the separate admin role-gate (wb-qfvt) — an owner of org B still gets 404 on org A's nexus.
    c = if org, do: c |> assign(:tenant, org) |> assign(:identity, %{tenant: org, user: org <> "@t", roles: ["owner"]}), else: c
    Nexus.Platform.call(c, @opts)
  end

  setup do
    System.put_env("WB_CONTROL_PLANE", "1")
    Nexus.ControlPlane.reset()
    prev = Application.get_env(:nexus, :auth)
    Application.put_env(:nexus, :auth, Nexus.Auth.Bearer) # non-None → multi? true
    # Provisioning goes through the injected Fly stub — no network.
    Application.put_env(:nexus, :fly_client, __MODULE__.StubFly)
    on_exit(fn ->
      System.delete_env("WB_CONTROL_PLANE")
      Application.delete_env(:nexus, :fly_client)
      if prev, do: Application.put_env(:nexus, :auth, prev), else: Application.delete_env(:nexus, :auth)
    end)
  end

  defmodule StubFly do
    def create_app(_app, _org, _opts), do: {:ok, %{}}
    def create_machine(app, _config, _opts), do: {:ok, %{"id" => "m_" <> app}}
    def destroy_machine(_a, _i, _o), do: {:ok, %{}}
    def delete_app(_a, _o), do: {:ok, %{}}
    def start_machine(_a, _i, _o), do: {:ok, %{}}
    def stop_machine(_a, _i, _o), do: {:ok, %{}}
    def get_machine(_a, _i, _o), do: {:ok, %{"state" => "started"}}
  end

  test "control-plane OFF → every platform route 404s (indistinguishable from a tenant runtime)" do
    System.delete_env("WB_CONTROL_PLANE")
    assert call(:get, "/nexuses", "org_x").status == 404
  end

  test "no real org identity (None auth) → 403, never wide-open" do
    Application.put_env(:nexus, :auth, Nexus.Auth.None)
    assert call(:get, "/nexuses", "org_x").status == 403
  end

  test "missing tenant → 403" do
    assert call(:get, "/nexuses", nil).status == 403
  end

  test "tokens: mint → list → revoke round-trips for the org (regression: decode the JSON body)" do
    # Regression for the 500 that broke the dashboard's 'Generate token': the handler indexed the RAW
    # body string (`read(conn)["name"]`) instead of the decoded map → Access.get on a string crashed.
    minted = call(:post, "/tokens/mint", "org_tok", %{name: "ci-push"})
    assert minted.status == 201
    body = Jason.decode!(minted.resp_body)
    assert String.starts_with?(body["token"], "wbk_")
    assert body["name"] == "ci-push"

    listed = call(:get, "/tokens", "org_tok") |> then(&Jason.decode!(&1.resp_body))
    assert Enum.any?(listed["tokens"], &(&1["id"] == body["id"]))
    # the plaintext is shown once on mint, never on list
    refute Enum.any?(listed["tokens"], &Map.has_key?(&1, "token"))

    assert call(:delete, "/tokens/#{body["id"]}", "org_tok").status == 200
    after_list = call(:get, "/tokens", "org_tok") |> then(&Jason.decode!(&1.resp_body))
    refute Enum.any?(after_list["tokens"], &(&1["id"] == body["id"]))
  end

  test "tokens/mint with no body defaults the name (no crash)" do
    assert call(:post, "/tokens/mint", "org_tok2").status == 201
  end

  test "a nexus created by org A is invisible + untouchable to org B over HTTP" do
    created = call(:post, "/nexuses", "org_http_a", %{name: "A-prod"})
    assert created.status == 201
    id = Jason.decode!(created.resp_body)["id"]

    # B lists → does not include A's nexus
    b_list = call(:get, "/nexuses", "org_http_b") |> then(& Jason.decode!(&1.resp_body))
    refute Enum.any?(b_list["nexuses"], &(&1["id"] == id)), "org B saw org A's nexus over HTTP — IDOR!"

    # B GETs A's exact id → 404
    assert call(:get, "/nexuses/#{id}", "org_http_b").status == 404
    # B tries to tear down A's nexus → ownership-gated 404, and A still has it intact.
    assert call(:delete, "/nexuses/#{id}", "org_http_b").status == 404
    assert call(:get, "/nexuses/#{id}", "org_http_a").status == 200
  end

  test "workspace CRUD round-trips for the owning org" do
    c = call(:post, "/workspaces", "org_ws_a", %{name: "Design", icon: "🎨"})
    assert c.status == 201
    list = call(:get, "/workspaces", "org_ws_a") |> then(& Jason.decode!(&1.resp_body))
    assert Enum.any?(list["workspaces"], &(&1["name"] == "Design"))
  end

  # wb-qfvt: sensitive control-plane mutations require admin+, not any org member.
  test "a member (non-admin) is 403'd from sensitive platform mutations" do
    member = fn method, path ->
      conn(method, path)
      |> assign(:tenant, "org_q")
      |> assign(:identity, %{tenant: "org_q", user: "m@t", roles: ["member"]})
      |> Nexus.Platform.call(@opts)
    end

    assert member.(:get, "/env/anything/reveal").status == 403
    assert member.(:post, "/members/invite").status == 403
    assert member.(:delete, "/domains/x").status == 403
    # default-deny plug closes the routes the per-route pass missed (wb-k5i0), incl. the destructive one
    assert member.(:delete, "/workspaces/x").status == 403
    assert member.(:patch, "/nexuses/x").status == 403
    assert member.(:post, "/workspaces").status == 403
    # ...but a member may still mint their own CLI PAT (allowlisted; inherits their role)
    assert member.(:post, "/tokens/mint").status != 403
  end
end
