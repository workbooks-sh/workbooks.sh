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

  # The HTTP/WS surface is opt-in (WB_WEB=1) so the demo boots without binding a port.
  defp web do
    if System.get_env("WB_WEB") == "1" do
      [{Bandit, plug: Workbooks.Web, scheme: :http, port: port()}]
    else
      []
    end
  end

  defp port, do: String.to_integer(System.get_env("PORT", "4000"))
end
