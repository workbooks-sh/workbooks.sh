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
      # No bearer: try our OWN native session cookie (Nexus.Auth.Session, set by /auth/login). The
      # browser dashboard authenticates this way. Falling back: gate the org-data API (401), but leave
      # the public surfaces open as the default tenant — one nexus serves its website AND control plane.
      "" ->
        case session_identity(conn) do
          {:ok, identity} ->
            {:ok, identity}

          :none ->
            if String.starts_with?(path, @gated),
              do: {:error, :unauthorized},
              else: {:ok, %{tenant: Nexus.Store.default_tenant(), user: nil}}
        end

      # A presented credential resolves to its org on ANY path (CLI + dashboard both authenticate here).
      "wbk_" <> _ = token ->
        case Nexus.ControlPlane.Token.resolve(token) do
          {:ok, org} -> {:ok, %{tenant: org, user: "cli"}}
          :error -> {:error, :unauthorized}
        end

      # A non-PAT bearer is a WorkOS JWT (legacy transition path — removed once native login is the only
      # way in).
      _ ->
        Nexus.Auth.Jwt.authenticate(conn)
    end
  end

  # The native session cookie → its identity (which carries `:tenant`), or `:none` if absent/invalid.
  defp session_identity(conn) do
    case Nexus.Auth.Session.verify(Plug.Conn.fetch_cookies(conn)) do
      {:ok, %{tenant: t} = id} when is_binary(t) and t != "" -> {:ok, id}
      {:ok, %{tenant: t} = id, :renew} when is_binary(t) and t != "" -> {:ok, id}
      _ -> :none
    end
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> t | _] -> String.trim(t)
      _ -> ""
    end
  end
end
