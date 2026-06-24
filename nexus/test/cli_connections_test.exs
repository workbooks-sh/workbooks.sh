defmodule Nexus.CliConnectionsTest do
  use ExUnit.Case, async: false
  alias Nexus.CliConnections, as: Cli
  alias Nexus.ControlPlane, as: CP
  alias Nexus.ControlPlane.Env
  alias Nexus.ConnectionPolicy, as: Policy

  @master Base.encode64(:binary.copy(<<0>>, 32))
  @org "org_clicon"

  setup do
    System.put_env("WB_CONTROL_PLANE", "1")
    System.put_env("WB_ENV_MASTER_KEY", @master)

    {:ok, env} = Env.create(@org, %{name: "GWS_CRED", value: "ya29.secret", scope: "user"})

    {:ok, _} =
      CP.put(@org, :integration, "intg_gws", %{
        provider: "google",
        label: "acme.com",
        cli: "gws",
        env_var: "GOOGLE_WORKSPACE_CLI_TOKEN",
        cred_kind: "token",
        token_secret_id: env[:id],
        command_grants: %{"drive" => "drive", "gmail" => "gmail", "admin" => "admin"},
        consumer_toolkits: ["google-workspace"]
      })

    on_exit(fn ->
      CP.delete(@org, :integration, "intg_gws")
      Env.delete(@org, env[:id])
      System.delete_env("WB_ENV_MASTER_KEY")
    end)

    :ok
  end

  test "run_opts binds the active connection when its consumer toolkit is in caps" do
    opts = Cli.run_opts(@org, ["google-workspace", "research"])
    assert Keyword.get(opts, :env) == ["GOOGLE_WORKSPACE_CLI_TOKEN=ya29.secret"]
    assert is_function(Keyword.get(opts, :exec_policy), 1)
  end

  test "run_opts is empty when no consumer toolkit is active" do
    assert Cli.run_opts(@org, ["research"]) == []
    assert Cli.run_opts(@org, []) == []
  end

  test "exec policy gates the cli binary by command group, fails closed on a blocked grant" do
    {:ok, ["drive"]} = Policy.set(@org, "intg_gws", ["drive"])
    policy = Keyword.get(Cli.run_opts(@org, ["google-workspace"]), :exec_policy)

    assert policy.(["gws", "drive", "list"]) == :ok
    assert {:deny, _} = policy.(["gws", "admin", "users"])
    # gating is scoped to the cli binary — a non-gws command with a matching word passes
    assert policy.(["echo", "admin"]) == :ok
  end

  test "opts_for_id resolves a specific connection (app-facing twin)" do
    opts = Cli.opts_for_id(@org, "intg_gws")
    assert Keyword.get(opts, :env) == ["GOOGLE_WORKSPACE_CLI_TOKEN=ya29.secret"]
    assert Cli.opts_for_id(@org, "intg_missing") == []
  end

  test "a credentials_file connection writes the path env + a file spec" do
    {:ok, env} = Env.create(@org, %{name: "GWS_FILE", value: "{\"sa\":1}", scope: "user"})

    {:ok, _} =
      CP.put(@org, :integration, "intg_file", %{
        provider: "google", label: "beta", cli: "gws",
        env_var: "GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE", cred_kind: "credentials_file",
        token_secret_id: env[:id], command_grants: %{}, consumer_toolkits: ["google-workspace"]
      })

    opts = Cli.opts_for_id(@org, "intg_file")
    assert Keyword.get(opts, :env) == ["GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE=/work/.cred/intg_file.json"]
    assert [%{path: "/work/.cred/intg_file.json", content: "{\"sa\":1}"}] = Keyword.get(opts, :files)

    CP.delete(@org, :integration, "intg_file")
    Env.delete(@org, env[:id])
  end
end
