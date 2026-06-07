defmodule Workbooks.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Workbooks.Auth.Guardian.install_config()

    children =
      [
        {Registry, keys: :unique, name: Workbooks.Instance.Registry},
        {Registry, keys: :unique, name: Workbooks.AgentSession.Registry},
        Workbooks.OQL,
        Workbooks.ControlPlane,
        Workbooks.Vars,
        Workbooks.Memory,
        Workbooks.Instance.Supervisor,
        {DynamicSupervisor, strategy: :one_for_one, name: Workbooks.AgentSession.Sup}
      ] ++ web()

    Supervisor.start_link(children, strategy: :one_for_one, name: Workbooks.Supervisor)
  end

  # The HTTP surfaces are opt-in so the demo boots without binding a port.
  # Two SEPARATE listeners / planes (PUBLIC-WEB-PLAN.org):
  #   WB_WEB=1     → control plane (authed): Workbooks.Web on PORT (default 4000)
  #   WB_PUBLIC=1  → content plane (anonymous, GET-only): Workbooks.PublicWeb on
  #                  PUBLIC_PORT (default 4001). Distinct listener so public traffic
  #                  never shares the authed router or its pipeline.
  defp web do
    control =
      if System.get_env("WB_WEB") == "1" do
        [Supervisor.child_spec({Bandit, plug: Workbooks.Web, scheme: :http, port: port()}, id: :control_web)]
      else
        []
      end

    public =
      if System.get_env("WB_PUBLIC") == "1" do
        [Supervisor.child_spec({Bandit, plug: Workbooks.PublicWeb, scheme: :http, port: public_port()}, id: :public_web)]
      else
        []
      end

    control ++ public
  end

  defp port, do: String.to_integer(System.get_env("PORT", "4000"))
  defp public_port, do: String.to_integer(System.get_env("PUBLIC_PORT", "4001"))
end
