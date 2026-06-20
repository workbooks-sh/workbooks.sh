defmodule Nexus.Auth.Cloud do
  @moduledoc """
  Control-plane auth adapter: accept EITHER a CLI personal-access token
  (`Authorization: Bearer wbk_…`, resolved by `Nexus.ControlPlane.Token`) OR a
  WorkOS JWT (delegated to `Nexus.Auth.Jwt`). The dashboard logs in with a JWT;
  the `work` CLI uses a minted PAT. Both resolve to the same `org` tenant, so
  `/api/platform` is identical for browser and CLI.

  The control plane selects this adapter (see `Nexus.ControlPlane.configure/0`),
  which still configures `Nexus.Auth.Jwt` underneath so the JWT path keeps working.

  **Scoped gate.** A control-plane nexus is ALSO an ordinary nexus serving its own (often public)
  website. Only the org-data API (`/api/platform`) requires an org identity; every other path — the
  served workbooks, the dashboard UI shell, assets — resolves to the default (public) tenant, exactly
  as on a non-control-plane nexus. So one nexus can be site + control plane without the platform gate
  locking down the public surfaces.
  """
  @behaviour Nexus.Auth
  import Plug.Conn, only: [get_req_header: 2]

  @gated "/api/platform"

  @impl true
  def authenticate(%{request_path: path} = conn) do
    case bearer(conn) do
      # No credential: gate the org-data API (401), but leave the public surfaces open as the default
      # tenant — so one nexus serves its public website AND the control plane.
      "" ->
        if String.starts_with?(path, @gated),
          do: {:error, :unauthorized},
          else: {:ok, %{tenant: Nexus.Store.default_tenant(), user: nil}}

      # A presented credential resolves to its org on ANY path (CLI + dashboard both authenticate here).
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
