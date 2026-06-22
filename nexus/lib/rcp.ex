defmodule Nexus.Rcp do
  @moduledoc """
  The RCP (runtime-connect) capabilities handshake — the public doc served at
  `GET /.well-known/workbooks-runtime` that the desktop/web RCP client fetches FIRST to learn how to
  talk to this runtime (protocol version, tenancy, auth rung, transports, capability names). Without
  it the client degrades to "unavailable". Public (no credential) — it exposes only how to
  authenticate, never any tenant data.
  """
  @rcp_version "1"

  @doc "The capabilities handshake doc (a plain map → JSON at the route)."
  def capabilities do
    multi = Nexus.Auth.multi?()
    jwt = Application.get_env(:nexus, Nexus.Auth.Jwt, [])

    %{
      rcp: @rcp_version,
      runtime: to_string(Application.spec(:nexus, :vsn) || "dev"),
      tenancy: if(multi, do: "multi", else: "single"),
      auth: %{
        rung: if(multi, do: "oidc-jwt", else: "trusted"),
        issuer: jwt[:iss],
        jwks_url: jwt[:jwks_url]
      },
      # ws: the duplex live channel at GET /ws (Nexus.Ws) — run streaming + bidirectional steering.
      transports: %{http: true, ws: true},
      capabilities: caps()
    }
  end

  # What this runtime can do, by name. Every runtime serves the workbook data plane; the control-plane
  # role adds the platform fleet API.
  defp caps do
    base = ["data"]
    if Nexus.ControlPlane.enabled?(), do: base ++ ["platform"], else: base
  end
end
