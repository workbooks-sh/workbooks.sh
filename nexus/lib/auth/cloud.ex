defmodule Nexus.Auth.Cloud do
  @moduledoc """
  Control-plane auth adapter: accept EITHER a CLI personal-access token
  (`Authorization: Bearer wbk_…`, resolved by `Nexus.ControlPlane.Token`) OR a
  WorkOS JWT (delegated to `Nexus.Auth.Jwt`). The dashboard logs in with a JWT;
  the `work` CLI uses a minted PAT. Both resolve to the same `org` tenant, so
  `/api/platform` is identical for browser and CLI.

  The control plane selects this adapter (see `Nexus.ControlPlane.configure/0`),
  which still configures `Nexus.Auth.Jwt` underneath so the JWT path keeps working.
  """
  @behaviour Nexus.Auth
  import Plug.Conn, only: [get_req_header: 2]

  @impl true
  def authenticate(conn) do
    case bearer(conn) do
      "wbk_" <> _ = token ->
        case Nexus.ControlPlane.Token.resolve(token) do
          {:ok, org} -> {:ok, %{tenant: org, user: "cli"}}
          :error -> {:error, :unauthorized}
        end

      _ ->
        Nexus.Auth.Jwt.authenticate(conn)
    end
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> t | _] -> String.trim(t)
      _ -> ""
    end
  end
end
