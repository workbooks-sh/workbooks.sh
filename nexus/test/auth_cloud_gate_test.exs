defmodule Nexus.AuthCloudGateTest do
  @moduledoc """
  The Cloud auth adapter gate (wb-review-p0.7). Exercises the REAL `Nexus.Auth.Cloud.authenticate/1`
  (not a hand-built conn with a preset tenant) so it catches the fail-OPEN asymmetry the earlier
  cloud_api_test missed: an unauthenticated `/api/cloud/*` read must 401, not fall through to the
  default public tenant. Public site paths must still resolve to the default tenant.
  """
  use ExUnit.Case, async: true
  import Plug.Test

  defp auth(path), do: Nexus.Auth.Cloud.authenticate(conn(:get, path))

  test "unauthenticated org-data APIs are gated (401), not default-tenant" do
    assert auth("/api/platform/me") == {:error, :unauthorized}
    assert auth("/api/cloud/tools") == {:error, :unauthorized}
    assert auth("/api/cloud/channels/numbers") == {:error, :unauthorized}
  end

  test "unauthenticated public surfaces resolve to the default (public) tenant" do
    assert {:ok, %{user: nil, tenant: t}} = auth("/cloud/")
    assert is_binary(t)
    assert {:ok, %{user: nil}} = auth("/docs/")
    assert {:ok, %{user: nil}} = auth("/api/email/inbound")
  end

  test "an unissued bearer is rejected on the gated API, public elsewhere" do
    gated = Nexus.Auth.Cloud.authenticate(bearer("/api/cloud/tools", "not-a-real-token"))
    assert gated == {:error, :unauthorized}

    public = Nexus.Auth.Cloud.authenticate(bearer("/cloud/", "not-a-real-token"))
    assert {:ok, %{user: nil}} = public
  end

  defp bearer(path, token) do
    conn(:get, path) |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
  end
end
