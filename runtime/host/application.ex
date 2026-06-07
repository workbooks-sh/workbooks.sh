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
        Workbooks.Instance.Supervisor,
        Workbooks.Domains,
        {DynamicSupervisor, strategy: :one_for_one, name: Workbooks.AgentSession.Sup}
      ] ++ web()

    result = Supervisor.start_link(children, strategy: :one_for_one, name: Workbooks.Supervisor)
    # Pre-warm the semantic embedder in the background (no-op unless WB_EMBED=local)
    # so the first search/index isn't blocked on the model download.
    Workbooks.Embed.Model2Vec.warm()
    result
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

    # WB_PUBLIC_TLS=1 → the content plane over HTTPS with per-host certs chosen at
    # handshake by Workbooks.Domains.sni/1 (one node, many domains, no Caddy).
    public_tls =
      if System.get_env("WB_PUBLIC_TLS") == "1" do
        [
          Supervisor.child_spec(
            {Bandit,
             plug: Workbooks.PublicWeb,
             scheme: :https,
             port: public_tls_port(),
             thousand_island_options: [transport_options: [sni_fun: &Workbooks.Domains.sni/1]]},
            id: :public_web_tls
          )
        ]
      else
        []
      end

    control ++ public ++ public_tls
  end

  defp port, do: String.to_integer(System.get_env("PORT", "4000"))
  defp public_port, do: String.to_integer(System.get_env("PUBLIC_PORT", "4001"))
  defp public_tls_port, do: String.to_integer(System.get_env("PUBLIC_TLS_PORT", "4443"))
end
