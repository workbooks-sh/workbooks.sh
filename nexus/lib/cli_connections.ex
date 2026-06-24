defmodule Nexus.CliConnections do
  @moduledoc """
  Bind a run's active CLI-backed connection to the shell — the call-site that turns "this agent run
  may use Google Workspace" into a real `gws` invocation with credentials in its env and its scope
  enforced. The generic counterpart to `Nexus.ConnectionPolicy`: this resolves WHICH connection is
  active and builds the `Nexus.Shell.run/3` opts; the policy module answers whether a grant is allowed.

  Generic by construction — it reads only opaque fields off the `:integration` record (`cli`,
  `command_grants`, `env_var`, `cred_kind`, `consumer_toolkits`) that the app denormalised at connect
  time, plus the encrypted credential. It carries no provider catalog, so the open-standard runtime
  stays free of our (or any deployer's) Google/gws specifics.

  Resolution: a connection is active for a run when one of its `consumer_toolkits` is in the run's
  `caps` (the composer's capability selection). The first such CLI connection wins (single-connection
  is the common case; multi-connection disambiguation is a future refinement).
  """

  alias Nexus.ControlPlane, as: CP
  alias Nexus.ControlPlane.Env
  alias Nexus.ConnectionPolicy, as: Policy

  @doc """
  Shell.run opts for the CLI connection active in this run, or `[]` when none is. `caps` is the run's
  active capability list (`perms[:caps]`). Returns `[env: [...], exec_policy: fn, files: [...]]`.
  """
  def run_opts(tenant, caps) when is_binary(tenant) and is_list(caps) do
    case active(tenant, caps) do
      nil -> []
      rec -> opts_for(tenant, rec[:id], rec)
    end
  end

  def run_opts(_tenant, _caps), do: []

  @doc "Shell.run opts for a specific connection id (app-facing twin of run_opts/2). `[]` if unknown."
  def opts_for_id(tenant, id) do
    case CP.get(tenant, :integration, id) do
      {:ok, rec} -> opts_for(tenant, id, rec)
      _ -> []
    end
  end

  # The first CLI-backed connection whose consumer toolkit is selected for this run.
  defp active(tenant, caps) do
    CP.list(tenant, :integration)
    |> Enum.find(fn r ->
      is_binary(r[:cli]) and Enum.any?(r[:consumer_toolkits] || [], &(&1 in caps))
    end)
  end

  @doc """
  Build `[env:, exec_policy:, files:]` from a denormalised CLI connection record. The credential is
  revealed here (only the running CLI ever sees it, as its own process env); the exec policy gates the
  connection's CLI binary by command group against the tenant's allow-list, failing closed otherwise.
  """
  def opts_for(tenant, id, rec) do
    case Env.reveal(tenant, rec[:token_secret_id]) do
      {:ok, value} ->
        {env, files} = credential(id, rec, value)
        [env: env, exec_policy: policy(tenant, id, rec), files: files]

      _ ->
        []
    end
  end

  # A token is injected inline as an env var; a credentials file is written into the run's /work and the
  # env var points at it (a per-connection path so two connections never collide).
  defp credential(id, rec, value) do
    env_var = rec[:env_var]

    case rec[:cred_kind] do
      "credentials_file" ->
        path = "/work/.cred/#{id}.json"
        {["#{env_var}=#{path}"], [%{path: path, content: value, env: env_var}]}

      _ ->
        {["#{env_var}=#{value}"], []}
    end
  end

  defp policy(tenant, id, rec) do
    cli = rec[:cli]
    grants = rec[:command_grants] || %{}

    fn argv ->
      case argv do
        [bin | _] when bin == cli and grants != %{} ->
          case Policy.argv_grant(grants, argv) do
            nil ->
              :ok

            grant ->
              if Policy.allowed?(tenant, id, grant),
                do: :ok,
                else: {:deny, "#{grant} is not enabled for this connection"}
          end

        _ ->
          :ok
      end
    end
  end
end
