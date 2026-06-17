defmodule Workbooks.Web.Platform do
  @moduledoc """
  Pure shaping helpers for the hosted "nexus" platform control-plane routes in
  `Workbooks.Web` — view projection, body→opts parsing, and formatting. No
  `conn`, no IO: the router handles request/response, these shape the data.
  """

  # Shape a registry row OR a provision result (both atom-keyed) into the dashboard's
  # nexus view. The per-nexus bearer/DSN are never in either source.
  def nexus_view(nx) do
    app = nx[:fly_app] || ""

    %{
      id: nx[:id],
      name: nx[:name] || nx[:id],
      region: nx[:region] || "",
      plan: nx[:plan] || "starter",
      state: map_state(nx[:state]),
      url: nx[:url] || (if app != "", do: "https://#{app}.fly.dev", else: "")
    }
  end

  # registry lifecycle vocab → the dashboard's vocab.
  defp map_state("running"), do: "run"
  defp map_state("stopped"), do: "sleep"
  defp map_state(_), do: "build"

  # Only name/region/plan are accepted from the body; the org, secrets, image and Fly
  # org are all pinned server-side in the provisioner — never caller input.
  def provision_opts(body) do
    case Jason.decode(body) do
      {:ok, %{} = m} -> [] |> put_opt(:name, m["name"]) |> put_opt(:region, m["region"]) |> put_opt(:plan, m["plan"])
      _ -> []
    end
  end

  defp put_opt(opts, _k, v) when v in [nil, ""], do: opts
  defp put_opt(opts, k, v), do: Keyword.put(opts, k, v)

  # Workspace create body → %{name, icon, nexus_id}. Only these fields are read;
  # the org comes from the tenant, never the body.
  def workspace_params(body) do
    case Jason.decode(body) do
      {:ok, %{} = m} -> %{name: m["name"], icon: m["icon"], nexus_id: blank_to_nil(m["nexus_id"])}
      _ -> %{name: nil, icon: nil, nexus_id: nil}
    end
  end

  defp blank_to_nil(v) when v in [nil, ""], do: nil
  defp blank_to_nil(v), do: v

  def platform_storage_bytes(org) do
    Workbooks.Storage.usage_bytes(org)
  rescue
    _ -> 0
  catch
    _, _ -> 0
  end

  def gb(bytes) when is_number(bytes),
    do: :erlang.float_to_binary(bytes / 1_000_000_000, decimals: 2) <> " GB"

  def gb(_), do: "0 GB"

  def reason_str(r) when is_atom(r), do: Atom.to_string(r)
  def reason_str(r), do: inspect(r)

  # The role→capability legend, for the dashboard "Roles & access" surface.
  def rbac_matrix do
    Map.new(Workbooks.RBAC.roles(), fn r -> {r, Workbooks.RBAC.capabilities(r)} end)
  end
end
