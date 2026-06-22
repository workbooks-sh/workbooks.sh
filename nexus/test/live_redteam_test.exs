defmodule Nexus.LiveRedteamTest do
  @moduledoc """
  LIVE red-team — boots a REAL `Bandit` server (the full plug pipeline: `Nexus.Auth` → `/api/platform`
  + `/git` smart-HTTP via the real `git http-backend`) in MULTI-TENANT `auth=Cloud` mode, then attacks
  it OVER THE WIRE with two orgs' real PATs. Not `Plug.Test` — actual TCP, actual git child process.

  Proves, against a running nexus, the classes the static audit flagged:
    * unauthenticated control-plane API is closed (401), public surfaces stay open;
    * cross-org IDOR is impossible (org B can't see/read/delete org A's nexus → 404);
    * client-supplied `?tenant=`/identity is IGNORED — scope comes from the PAT, never the URL;
    * sensitive platform mutations are admin-gated (member → 403), but a member may mint their own PAT;
    * git transport binds to THIS nexus's org (foreign-org PAT → 403) and gates anonymous push.

  Skips cleanly if git is unavailable.
  """
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag timeout: 120_000

  @port 4099
  @base ~c"http://127.0.0.1:#{@port}"

  setup_all do
    if System.find_executable("git") do
      Application.ensure_all_started(:inets)

      # Multi-tenant, real cloud auth + control plane on. NEXUS_TENANT pins THIS nexus's org = org_a, so
      # the git transport's org boundary (authorize/3) accepts org_a and rejects org_b.
      prev_auth = Application.get_env(:nexus, :auth)
      Application.put_env(:nexus, :auth, Nexus.Auth.Cloud)
      System.put_env("WB_CONTROL_PLANE", "1")
      System.put_env("NEXUS_TENANT", "org_a")

      # Scope all durable state to a throwaway dir.
      base = Path.join(System.tmp_dir!(), "wb-live-#{System.unique_integer([:positive])}")
      File.mkdir_p!(base)
      prev_data = System.get_env("WB_DATA")
      System.put_env("WB_DATA", base)

      # Minimal served root (one trivial workbook) — the attacks target server-level /api/platform + /git,
      # not a mounted workbook's routes, so we don't pay the dogfood/cloud compile cost.
      root = Path.join(base, "wb")
      File.mkdir_p!(root)
      File.write!(Path.join(root, "index.work"), "Live red-team target.\n")

      Nexus.ControlPlane.reset()
      Nexus.Auth.TokenStore.ensure(:cp_tokens)

      {:ok, pid} = Nexus.Server.start_link(root: root, port: @port)
      wait_health()

      on_exit(fn ->
        if Process.alive?(pid), do: Process.exit(pid, :kill)
        Application.delete_env(:nexus, :fly_client)
        if prev_auth, do: Application.put_env(:nexus, :auth, prev_auth), else: Application.delete_env(:nexus, :auth)
        if prev_data, do: System.put_env("WB_DATA", prev_data), else: System.delete_env("WB_DATA")
        System.delete_env("WB_CONTROL_PLANE")
        System.delete_env("NEXUS_TENANT")
        File.rm_rf(base)
      end)

      # Provisioning goes through a stub — no Fly network.
      Application.put_env(:nexus, :fly_client, __MODULE__.StubFly)

      # Real PATs for two orgs at three authority levels.
      a_owner = Nexus.ControlPlane.Token.mint("org_a", "a-own", role: "owner", user: "a@t").token
      a_member = Nexus.ControlPlane.Token.mint("org_a", "a-mem", role: "member", user: "m@t").token
      b_owner = Nexus.ControlPlane.Token.mint("org_b", "b-own", role: "owner", user: "b@t").token

      # org_a's ONE nexus (one-per-org guard) — created once, shared by the cross-org tests.
      {201, created} = req(:post, "/api/platform/nexuses", a_owner, %{name: "A-prod"})

      {:ok, a_owner: a_owner, a_member: a_member, b_owner: b_owner, a_nexus_id: created["id"]}
    else
      {:ok, skip: true}
    end
  end

  defmodule StubFly do
    def create_app(_a, _o, _x), do: {:ok, %{}}
    def create_machine(app, _c, _o), do: {:ok, %{"id" => "m_" <> app}}
    def destroy_machine(_a, _i, _o), do: {:ok, %{}}
    def delete_app(_a, _o), do: {:ok, %{}}
    def start_machine(_a, _i, _o), do: {:ok, %{}}
    def stop_machine(_a, _i, _o), do: {:ok, %{}}
    def get_machine(_a, _i, _o), do: {:ok, %{"state" => "started"}}
  end

  # --- HTTP helpers (real sockets via :httpc) ---------------------------------

  defp req(method, path, token \\ nil, body \\ nil) do
    headers =
      [{~c"accept", ~c"application/json"}] ++
        if(token, do: [{~c"authorization", String.to_charlist("Bearer " <> token)}], else: [])

    url = @base ++ String.to_charlist(path)

    request =
      if body do
        {url, headers, ~c"application/json", Jason.encode!(body)}
      else
        {url, headers}
      end

    {:ok, {{_, status, _}, _h, resp}} =
      :httpc.request(method, request, [{:timeout, 30_000}], [{:body_format, :binary}])

    {status, decode(resp)}
  end

  defp decode(b) do
    case Jason.decode(b) do
      {:ok, m} -> m
      _ -> b
    end
  end

  defp wait_health(n \\ 100) do
    case :httpc.request(:get, {@base ++ ~c"/health", []}, [{:timeout, 1000}], []) do
      {:ok, {{_, 200, _}, _, _}} -> :ok
      _ when n > 0 -> Process.sleep(100); wait_health(n - 1)
      _ -> flunk("server never became healthy on :#{@port}")
    end
  end

  # --- The exploits -----------------------------------------------------------

  test "unauthenticated control-plane API is closed; public health is open", ctx do
    skipping?(ctx) && throw(:skip)
    assert {401, _} = req(:get, "/api/platform/nexuses")
    assert {200, _} = req(:get, "/health")
  end

  test "cross-org IDOR over the wire: org B cannot see/read/delete org A's nexus", ctx do
    skipping?(ctx) && throw(:skip)
    id = ctx.a_nexus_id
    assert is_binary(id)

    # B lists → A's nexus absent
    assert {200, list} = req(:get, "/api/platform/nexuses", ctx.b_owner)
    refute Enum.any?(list["nexuses"] || [], &(&1["id"] == id)), "IDOR: org B saw org A's nexus"

    # B reads/deletes A's exact id → ownership-gated 404 (not 200, not 403-leak)
    assert {404, _} = req(:get, "/api/platform/nexuses/#{id}", ctx.b_owner)
    assert {404, _} = req(:delete, "/api/platform/nexuses/#{id}", ctx.b_owner)
    # A still has it intact
    assert {200, _} = req(:get, "/api/platform/nexuses/#{id}", ctx.a_owner)
  end

  test "client-supplied ?tenant= is ignored — scope comes from the PAT, not the URL", ctx do
    skipping?(ctx) && throw(:skip)
    # B token, but forge the org in the query string → must STILL be scoped to org_b (A's nexus absent)
    assert {200, list} = req(:get, "/api/platform/nexuses?tenant=org_a&u=a@t&role=owner", ctx.b_owner)
    refute Enum.any?(list["nexuses"] || [], &(&1["id"] == ctx.a_nexus_id)),
           "forged ?tenant= let org B enumerate org A over the wire"
  end

  test "sensitive platform mutations are admin-gated; member may still mint own PAT", ctx do
    skipping?(ctx) && throw(:skip)
    assert {403, _} = req(:post, "/api/platform/members/invite", ctx.a_member, %{email: "x@t"})
    assert {403, _} = req(:get, "/api/platform/env/anything/reveal", ctx.a_member)
    assert {403, _} = req(:post, "/api/platform/workspaces", ctx.a_member, %{name: "X"})
    # allowlisted: a member mints their own CLI token (inherits their role)
    {s, _} = req(:post, "/api/platform/tokens/mint", ctx.a_member, %{name: "mine"})
    refute s == 403, "member was blocked from minting their own PAT"
  end

  test "git transport binds to this nexus's org: foreign-org PAT → 403, anonymous → 401", ctx do
    skipping?(ctx) && throw(:skip)
    path = ~c"/git/redteam.git/info/refs?service=git-upload-pack"

    # org_b PAT (foreign — nexus_org is org_a) → 403 over the real git smart-HTTP endpoint
    b_auth = basic("x", ctx.b_owner)
    {:ok, {{_, b_status, _}, _, _}} =
      :httpc.request(:get, {@base ++ path, [b_auth]}, [{:timeout, 30_000}], [])
    assert b_status == 403, "foreign-org PAT reached this nexus's git repos (got #{b_status})"

    # No credentials at all → 401 challenge
    {:ok, {{_, anon_status, _}, _, _}} =
      :httpc.request(:get, {@base ++ path, []}, [{:timeout, 30_000}], [])
    assert anon_status == 401, "anonymous git access was not challenged (got #{anon_status})"
  end

  defp basic(user, pass) do
    {~c"authorization", String.to_charlist("Basic " <> Base.encode64("#{user}:#{pass}"))}
  end

  defp skipping?(ctx), do: ctx[:skip] == true
end
