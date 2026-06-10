defmodule Workbooks.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    trace("begin")
    Workbooks.Auth.Guardian.install_config()
    trace("guardian ok")

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
      ] ++ web() ++ keeper()

    # Start children ONE BY ONE with a boot-trace, so a child that blocks in init
    # is pinpointed (and visible in <WB_DATA>/boot-trace.txt) instead of hanging
    # the whole app start opaquely.
    {:ok, sup} = Supervisor.start_link([], strategy: :one_for_one, name: Workbooks.Supervisor)

    Enum.each(children, fn spec ->
      trace("child start: #{child_label(spec)}")

      case Supervisor.start_child(sup, spec) do
        {:ok, _} -> trace("child ok: #{child_label(spec)}")
        {:error, reason} -> trace("child ERR: #{child_label(spec)} -> #{inspect(reason)}")
      end
    end)

    trace("all children up")

    # Desktop daemon: publish the discovery file (port + per-boot token) so the
    # Tauri shell can find + authenticate to the runtime inside the container.
    if Workbooks.Desktop.enabled?() do
      path = Workbooks.Desktop.write_discovery!()
      trace("discovery written: #{path}")
      require Logger
      Logger.info("desktop daemon — discovery written: #{path} (port #{Workbooks.Desktop.port()})")
    end

    # Pre-warm the semantic embedder in a TASK so a slow/blocking model load can
    # NEVER block application start (no-op unless WB_EMBED=local).
    Task.start(fn ->
      Workbooks.Embed.Model2Vec.warm()

      require Logger

      Logger.info(
        "search config — embed: #{Workbooks.Embed.adapter() |> Module.split() |> List.last()}, vectors: #{Workbooks.DB.backend()}, machine recommends: #{Workbooks.Embed.Capability.recommend()}"
      )
    end)

    trace("start: done")
    {:ok, sup}
  end

  defp child_label(spec), do: spec |> inspect() |> String.slice(0, 50)

  # Append a boot phase marker to <WB_DATA>/boot-trace.txt (mapped out of the
  # container) so a hang in start/2 is pinpointable. Best-effort, never raises.
  defp trace(msg) do
    dir = System.get_env("WB_DATA") || System.tmp_dir!()
    _ = File.write(Path.join(dir, "boot-trace.txt"), "#{msg}\n", [:append])
    :ok
  rescue
    _ -> :ok
  end

  # The HTTP surfaces are opt-in so the demo boots without binding a port.
  # Two SEPARATE listeners / planes (PUBLIC-WEB-PLAN.org):
  #   WB_WEB=1     → control plane (authed): Workbooks.Web on PORT (default 4000)
  #   WB_PUBLIC=1  → content plane (anonymous, GET-only): Workbooks.PublicWeb on
  #                  PUBLIC_PORT (default 4001). Distinct listener so public traffic
  #                  never shares the authed router or its pipeline.
  defp web do
    # Desktop daemon (WB_DESKTOP=1) implies the control plane, bound on all
    # interfaces (the container forwards host→guest) at the fixed desktop port.
    control =
      cond do
        Workbooks.Desktop.enabled?() ->
          [Supervisor.child_spec({Bandit, plug: Workbooks.Web, scheme: :http, ip: Workbooks.Desktop.bind_ip(), port: Workbooks.Desktop.port(), thousand_island_options: [transport_options: [ipv6_v6only: false]]}, id: :control_web)]

        System.get_env("WB_WEB") == "1" ->
          [Supervisor.child_spec({Bandit, plug: Workbooks.Web, scheme: :http, port: port()}, id: :control_web)]

        true ->
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

  # Keeper (wb-5vm): on-box agent scheduler for deployed engines where the control
  # plane is internal-only and GitHub-cron can't reach it. Enabled ONLY when
  # WB_KEEPER_DEF is set; otherwise excluded from the supervision tree entirely so
  # normal/dev deploys are not affected.
  defp keeper do
    if System.get_env("WB_KEEPER_DEF") do
      [Workbooks.Keeper]
    else
      []
    end
  end

  defp port, do: String.to_integer(System.get_env("PORT", "4000"))
  defp public_port, do: String.to_integer(System.get_env("PUBLIC_PORT", "4001"))
  defp public_tls_port, do: String.to_integer(System.get_env("PUBLIC_TLS_PORT", "4443"))
end
