defmodule Nexus.Auth.Cloud do
  @moduledoc """
  Control-plane auth adapter — OUR OWN identity, no third-party IdP. Accept EITHER our native session
  cookie (`Nexus.Auth.Session`, set by `/auth/login`; the browser dashboard) OR a CLI personal-access
  token (`Authorization: Bearer wbk_…`, resolved by `Nexus.ControlPlane.Token`). Both resolve to the
  same `org` tenant, so `/api/platform` is identical for browser and CLI.

  **Scoped gate.** A control-plane nexus is ALSO an ordinary nexus serving its own (often public)
  website. Only the org-data API (`/api/platform`) requires an org identity; every other path — the
  served workbooks, the dashboard UI shell, assets — resolves to the default (public) tenant, exactly
  as on a non-control-plane nexus. So one nexus can be site + control plane without the platform gate
  locking down the public surfaces.
  """
  @behaviour Nexus.Auth
  import Plug.Conn, only: [get_req_header: 2]

  # Org-data API namespaces that REQUIRE an org identity. Anything not listed here (served workbooks,
  # dashboard shell, assets, public runtime endpoints) resolves to the default public tenant — one nexus
  # is site + control plane. `/api/cloud` (the desktop-facing broker API) is gated alongside
  # `/api/platform`; without it an unauthenticated caller fell through to the default tenant on every
  # `/api/cloud/*` read (fail-OPEN asymmetry, wb-review-p0.7). A valid PAT still reaches these on any path.
  @gated ["/api/platform", "/api/cloud"]

  defp gated?(path), do: Enum.any?(@gated, &String.starts_with?(path, &1))

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

          # Past half-life — tell the plug to re-issue (slide) the cookie so an active user stays in.
          {:renew, identity} ->
            {:ok, identity, :renew}

          :none ->
            if gated?(path),
              do: {:error, :unauthorized},
              else: {:ok, %{tenant: Nexus.Store.default_tenant(), user: nil}}
        end

      # A CLI personal-access token resolves to its org on ANY path. It carries the
      # minting user's role + id so the headless CLI acts with real authority (not viewer).
      "wbk_" <> _ = token ->
        case Nexus.ControlPlane.Token.resolve(token) do
          {:ok, %{org: org} = rec} ->
            {:ok, %{tenant: org, user: rec.user || "cli", roles: List.wrap(rec.role)}}

          :error ->
            {:error, :unauthorized}
        end

      # Any other bearer is not a credential we issue → reject the gated API, public elsewhere.
      _ ->
        if gated?(path),
          do: {:error, :unauthorized},
          else: {:ok, %{tenant: Nexus.Store.default_tenant(), user: nil}}
    end
  end

  # The native session cookie → its identity (which carries `:tenant`), or `:none` if absent/invalid.
  defp session_identity(conn) do
    case Nexus.Auth.Session.verify(Plug.Conn.fetch_cookies(conn)) do
      {:ok, %{tenant: t} = id} when is_binary(t) and t != "" -> {:ok, id}
      {:ok, %{tenant: t} = id, :renew} when is_binary(t) and t != "" -> {:renew, id}
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
