defmodule Workbooks.Web.Capabilities do
  @moduledoc """
  The RCP handshake document (RUNTIME-CONNECT-PROTOCOL.org §1). Served
  unauthenticated at `GET /.well-known/workbooks-runtime` so any client learns,
  BEFORE presenting a credential, (a) which auth rung this runtime requires and
  (b) what feature surface it exposes.

      {
        "rcp": "1",
        "runtime": "0.1.0",
        "tenancy": "single" | "multi",
        "auth": { "rung": "trusted" | "oidc-jwt",
                  "issuer": "<oidc issuer or null>",
                  "jwks_url": "<url or null>" },
        "transports": { "http": true, "ws": true },
        "capabilities": ["oql", "workflow", ...]
      }

  The auth RUNG is derived from tenancy: single-tenant accepts the `trusted`
  (local discovery token / anonymous dev) rung; multi-tenant REQUIRES `oidc-jwt`.
  `issuer`/`jwks_url` describe the configured IDP (BetterAuth by default) so an
  OIDC client adapter can self-configure.
  """
  @rcp "1"

  @doc "The capabilities/handshake map (JSON-encoded by the route)."
  def doc do
    jwks = System.get_env("WB_JWKS_URL")
    secret? = is_binary(System.get_env("WB_AUTH_SECRET"))
    issuer = System.get_env("WB_AUTH_ISSUER", "betterauth")

    %{
      rcp: @rcp,
      runtime: runtime_version(),
      tenancy: to_string(Workbooks.Tenancy.mode()),
      auth: %{
        rung: if(Workbooks.Tenancy.multi?(), do: "oidc-jwt", else: "trusted"),
        # Only advertise an issuer when a verifier is actually configured.
        issuer: if(jwks || secret?, do: issuer, else: nil),
        jwks_url: jwks
      },
      transports: %{http: true, ws: true},
      capabilities: ~w(oql workflow instances workbook agent library search publish browse telemetry)
    }
  end

  defp runtime_version do
    case :application.get_key(:workbooks, :vsn) do
      {:ok, v} -> to_string(v)
      _ -> "0.0.0"
    end
  end
end
