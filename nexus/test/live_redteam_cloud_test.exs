defmodule Nexus.LiveRedteamCloudTest do
  @moduledoc """
  LIVE red-team, part 2 — the CLOUD per-workspace ACL over the wire. Boots a REAL `Bandit` server with
  the ACTUAL `dogfood/cloud` workbook mounted (so the real `/cloud/*` routes from its `server.work`
  exist), in multi-tenant `auth=Cloud`, then attacks the draft/private write+read ACL with real PATs.

  Seeds one mounted workspace as a DRAFT owned by `owner@t` (a control-plane visibility record), then
  proves over real HTTP that a non-owner MEMBER is blocked on every path that touches it — the agent
  run, the file save, the file read, AND the tree enumeration — while an owner-role token still sees it.
  This exercises the SHARED authorizers (`workspace_write_ok?`/`may_write_workspace?`/`readable_mounts`)
  in the running pipeline, not via `Plug.Test`.

  Skips cleanly if git is unavailable.
  """
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag timeout: 300_000

  @port 4098
  @base ~c"http://127.0.0.1:#{@port}"

  setup_all do
    if System.find_executable("git") do
      Application.ensure_all_started(:inets)

      prev_auth = Application.get_env(:nexus, :auth)
      prev_policy = Application.get_env(:nexus, :authorship_policy)
      Application.put_env(:nexus, :auth, Nexus.Auth.Cloud)
      Application.put_env(:nexus, :authorship_policy, "soft")
      System.put_env("WB_CONTROL_PLANE", "1")
      System.put_env("NEXUS_TENANT", "org_a")

      base = Path.join(System.tmp_dir!(), "wb-livecloud-#{System.unique_integer([:positive])}")
      File.mkdir_p!(base)
      prev_data = System.get_env("WB_DATA")
      System.put_env("WB_DATA", base)

      # The cloud dashboard's workspaces are the subdirs of WB_DATA (data_dir — the git-pushed checkouts),
      # NOT the served root. So the attackable `secret` workspace lives under WB_DATA; we boot the real
      # dogfood/cloud as the root only to register its /cloud/* routes.
      File.mkdir_p!(Path.join(base, "secret"))
      File.write!(Path.join([base, "secret", "index.work"]), "Secret draft workspace.\n")
      cloud_root = Path.expand("../dogfood/cloud", File.cwd!())

      Nexus.ControlPlane.reset()
      Nexus.Auth.TokenStore.ensure(:cp_tokens)

      {:ok, pid} = Nexus.Server.start_link(root: cloud_root, port: @port)
      wait_health()

      # Flag `secret` a DRAFT owned by someone OTHER than our member.
      target = "secret"
      Nexus.ControlPlane.put("org_a", :visibility, target, %{id: target, state: "draft", owner: "owner@t"})

      # A valid agent name so agent_run reaches the ACL branch (not a 404), if any are registered.
      agent = (Enum.find(Nexus.Agent.all(), &(&1.name == "workhorse")) || List.first(Nexus.Agent.all()))
      agent_name = agent && agent.name

      member = Nexus.ControlPlane.Token.mint("org_a", "mem", role: "member", user: "m@t").token
      owner = Nexus.ControlPlane.Token.mint("org_a", "own", role: "owner", user: "a@t").token

      on_exit(fn ->
        if Process.alive?(pid), do: Process.exit(pid, :kill)
        if prev_auth, do: Application.put_env(:nexus, :auth, prev_auth), else: Application.delete_env(:nexus, :auth)
        if prev_policy, do: Application.put_env(:nexus, :authorship_policy, prev_policy), else: Application.delete_env(:nexus, :authorship_policy)
        if prev_data, do: System.put_env("WB_DATA", prev_data), else: System.delete_env("WB_DATA")
        System.delete_env("WB_CONTROL_PLANE")
        System.delete_env("NEXUS_TENANT")
        File.rm_rf(base)
      end)

      {:ok, target: target, member: member, owner: owner, agent: agent_name}
    else
      {:ok, skip: true}
    end
  end

  # --- HTTP over real sockets -------------------------------------------------

  defp req(method, path, token, body \\ nil) do
    headers =
      [{~c"accept", ~c"application/json"}, {~c"authorization", String.to_charlist("Bearer " <> token)}]

    url = @base ++ String.to_charlist(path)

    request =
      if body, do: {url, headers, ~c"application/json", Jason.encode!(body)}, else: {url, headers}

    {:ok, {{_, status, _}, _h, resp}} =
      :httpc.request(method, request, [{:timeout, 60_000}], [{:body_format, :binary}])

    {status, resp}
  end

  defp wait_health(n \\ 600) do
    case :httpc.request(:get, {@base ++ ~c"/health", []}, [{:timeout, 1000}], []) do
      {:ok, {{_, 200, _}, _, _}} -> :ok
      _ when n > 0 -> Process.sleep(200); wait_health(n - 1)
      _ -> flunk("cloud server never became healthy on :#{@port}")
    end
  end

  # --- The exploits: a non-owner member vs a draft owned by owner@t -----------

  test "member cannot RUN an agent against a draft workspace it doesn't own", ctx do
    skipping?(ctx) && throw(:skip)
    if ctx.agent do
      {status, _} = req(:post, "/cloud/agent/run", ctx.member, %{agent: ctx.agent, task: "probe", workspace: ctx.target})
      assert status == 403, "member ran an agent against a non-owned draft (got #{status})"
    else
      IO.puts("\n[skip] no agent registered — agent_run ACL branch not exercised")
    end
  end

  test "member cannot SAVE a file into a draft workspace it doesn't own", ctx do
    skipping?(ctx) && throw(:skip)
    file = Path.join([Nexus.Config.data_dir(), ctx.target, "index.work"])
    before = File.read!(file)

    {status, _} =
      req(:post, "/cloud/file/save", ctx.member, %{path: "#{ctx.target}/index.work", content: "pwned"})

    assert status == 403, "member wrote into a non-owned draft (got #{status})"
    assert File.read!(file) == before, "member's blocked save still mutated the file"
  end

  test "member cannot READ a file in a draft workspace it doesn't own", ctx do
    skipping?(ctx) && throw(:skip)
    {status, _} = req(:get, "/cloud/file?path=#{ctx.target}/index.work", ctx.member)
    assert status in [403, 404], "member read a non-owned draft file (got #{status})"
  end

  test "draft is hidden from a non-owner member's tree but visible to an owner", ctx do
    skipping?(ctx) && throw(:skip)
    {200, mem_tree} = req(:get, "/cloud/tree", ctx.member)
    {200, own_tree} = req(:get, "/cloud/tree", ctx.owner)

    refute String.contains?(mem_tree, ~s("#{ctx.target}")), "draft leaked into member's tree enumeration"
    assert String.contains?(own_tree, ~s("#{ctx.target}")), "owner could not see their own draft"
  end

  defp skipping?(ctx), do: ctx[:skip] == true
end
