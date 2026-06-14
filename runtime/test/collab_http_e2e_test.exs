defmodule Workbooks.CollabHttpE2eTest do
  @moduledoc """
  Production-wiring e2e: drives the ACTUAL Plug router (Workbooks.Web — auth →
  tenant assign → RBAC gate → endpoint → JSON) through the whole collaborative-
  workspaces arc, the way the dashboard/browser will: History → Restore → Undo →
  Drafts → Shared folders → Backup. Proves the routes + RBAC + JSON compose end to
  end over HTTP, not just the unit logic. (RBAC *denials* stay unit-tested — in dev
  x-tenant mode the identity is always the tenant-owner, so HTTP exercises the happy
  path + cross-tenant isolation.)
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Workbooks.{ControlPlane, Git}

  @auth_env ~w(WB_PUBLIC_BEARER WB_TENANCY_MODE WB_DESKTOP WB_AUTH_SECRET)

  setup do
    saved = for k <- @auth_env, do: {k, System.get_env(k)}
    for k <- @auth_env, do: System.delete_env(k)
    if function_exported?(Workbooks.Auth.Guardian, :install_config, 0), do: Workbooks.Auth.Guardian.install_config()

    prev = System.get_env("WB_DATA")
    data = Path.join(System.tmp_dir!(), "wb-e2e-#{System.unique_integer([:positive])}")
    File.mkdir_p!(data)
    System.put_env("WB_DATA", data)

    on_exit(fn ->
      for {k, v} <- saved, do: if(v, do: System.put_env(k, v), else: System.delete_env(k))
      if prev, do: System.put_env("WB_DATA", prev), else: System.delete_env("WB_DATA")
      File.rm_rf(data)
    end)

    :ok
  end

  defp req(method, path, tenant, body \\ nil) do
    c = conn(method, path, (body && Jason.encode!(body)) || "")
    c = if tenant, do: put_req_header(c, "x-tenant", tenant), else: c
    c = if body, do: put_req_header(c, "content-type", "application/json"), else: c
    Workbooks.Web.call(c, Workbooks.Web.init([]))
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)
  defp uniq(p), do: "#{p}-#{System.unique_integer([:positive])}"
  defp save(tenant, scope, org) do
    ControlPlane.put_workbook(scope, org, tenant)
    Git.save(%{tenant: tenant, author: tenant, email: "#{tenant}@workbooks.local"}, scope, org)
  end

  test "History → diff → Restore → Undo over HTTP" do
    t = uniq("acme")
    scope = uniq("home")
    save(t, scope, "* v1\n")
    save(t, scope, "* v1\n* v2\n")
    save(t, scope, "* v1\n* v2\n* v3\n")

    # timeline
    c = req(:get, "/api/history/#{scope}", t)
    assert c.status == 200
    changes = json(c)
    assert length(changes) == 3
    [latest, prev | _] = changes

    # before/after for the latest change
    c = req(:get, "/api/history/#{scope}/#{latest["id"]}/diff", t)
    assert c.status == 200
    assert %{"before" => _, "after" => after_} = json(c)
    assert after_ =~ "v3"

    # restore to the previous version → a NEW change appears (append-only)
    c = req(:post, "/api/history/#{scope}/restore", t, %{to: prev["id"]})
    assert c.status == 200
    assert json(c)["id"]
    assert length(json(req(:get, "/api/history/#{scope}", t))) == 4

    # undo the last change → another new change on top
    c = req(:post, "/api/history/#{scope}/undo", t)
    assert c.status == 200
    assert length(json(req(:get, "/api/history/#{scope}", t))) == 5

    # a DIFFERENT tenant cannot see this scope's history (cross-tenant isolation)
    assert req(:get, "/api/history/#{scope}", uniq("evil")).status == 404
  end

  test "Drafts lifecycle over HTTP: create → list → diff → discard" do
    t = uniq("beta")
    save(t, uniq("seed"), "* base\n")          # ensure the repo has a base commit

    # create
    c = req(:post, "/api/nexuses/#{t}/drafts", t, %{name: "spring"})
    assert c.status == 200
    assert json(c)["name"] == "spring"

    # list shows it
    c = req(:get, "/api/nexuses/#{t}/drafts", t)
    assert c.status == 200
    assert Enum.any?(json(c), &(&1["name"] == "spring"))

    # diff (no edits yet) → 200 empty
    assert req(:get, "/api/nexuses/#{t}/drafts/spring/diff", t).status == 200

    # discard
    assert req(:post, "/api/nexuses/#{t}/drafts/spring/discard", t).status == 200
    assert json(req(:get, "/api/nexuses/#{t}/drafts", t)) == []
  end

  test "Shared folders over HTTP: share → recipient lists + adds → confined copy" do
    owner = uniq("acme")
    mate = uniq("beta")
    # owner has a shareable folder under shared/, plus a root secret that must NOT travel
    dir = Git.ensure_repo(owner)
    File.mkdir_p!(Path.join(dir, "shared/brand"))
    File.write!(Path.join(dir, "shared/brand/logo.svg"), "<svg/>")
    File.write!(Path.join(dir, "secret.txt"), "DO-NOT-LEAK")
    Git.commit_and_push(dir, "seed", owner)

    # owner shares (dev x-tenant ⇒ owner role ⇒ :share allowed)
    c = req(:post, "/api/shared-folders/share", owner, %{folder: "brand", recipient: mate, mode: "read"})
    assert c.status == 200
    grant_id = json(c)["id"]

    # recipient sees it shared with them
    c = req(:get, "/api/shared-folders", mate)
    assert c.status == 200
    assert Enum.any?(json(c)["shared_with"], &(&1["id"] == grant_id))

    # recipient adds it → only the folder's files arrive, never the root secret
    c = req(:post, "/api/shared-folders/#{grant_id}/add", mate)
    assert c.status == 200
    assert json(c)["folder"] == "brand"
    mate_dir = Git.repo_path(mate)
    {files, 0} = System.cmd("git", ["-C", mate_dir, "ls-files"], stderr_to_stdout: true)
    assert files =~ "logo.svg"
    refute files =~ "secret"

    # a stranger holding the grant id cannot redeem it
    assert req(:post, "/api/shared-folders/#{grant_id}/add", uniq("evil")).status == 404
  end

  test "Backup over HTTP: status → connect → status" do
    t = uniq("gamma")
    save(t, uniq("home"), "* hi\n")

    # not connected initially
    assert json(req(:get, "/api/nexuses/#{t}/backup", t)) == %{"connected" => false, "url" => nil, "host" => nil}

    # connect to a local bare repo (real push, no network)
    bare = Path.join(System.tmp_dir!(), "wb-e2e-bare-#{System.unique_integer([:positive])}.git")
    {_, 0} = System.cmd("git", ["init", "--bare", "-q", bare], stderr_to_stdout: true)
    on_exit(fn -> File.rm_rf(bare) end)

    c = req(:post, "/api/nexuses/#{t}/backup/connect", t, %{url: "file://#{bare}"})
    assert c.status == 200
    assert json(c)["url"] == "file://#{bare}"

    # status now connected
    assert json(req(:get, "/api/nexuses/#{t}/backup", t))["connected"] == true
  end

  test "auth-integrations config is served over HTTP" do
    t = uniq("delta")
    c = req(:get, "/api/auth-integrations", t)
    assert c.status == 200
    body = json(c)
    assert body["active"] == "builtin"
    assert body["claim_map"] == %{"tenant" => "organizationId", "user" => "sub"}
  end
end
