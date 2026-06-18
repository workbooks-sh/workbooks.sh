defmodule WorkCore.DeployConfig do
  @moduledoc """
  The deployment config — a single `<work-deploy …>` HTML element (no JSON, on-canon). Two places
  (`engine-place="local|cloud"`), two tenancy modes, BYOD backends (`storage`, `database`, `auth`).
  Secrets never live in the file — they come from ENV. Pure: scaffold a starter, parse a file's
  attributes into uppercase property keys, and validate the combination (the coherence rules that
  stop an open control plane or a tenancy/auth mismatch). Shared by the `work` CLI and a nexus.
  """

  @places ~w(local cloud)
  @tenancy ~w(single multi)
  @storage ~w(local-fs s3)
  @database ~w(sqlite postgres)
  @auth ~w(trusted betterauth clerk oidc)

  @doc "A starter `deployment.html` for `place` (\"local\" | \"cloud\")."
  def scaffold(place) when place in @places do
    {extra, body_note} =
      if place == "cloud" do
        {~s(\n  provider="fly"\n  app="my-workbook"\n  region="iad"), "<!-- cloud: set WB_DATABASE_URL / WB_S3_* in your deploy ENV, never here -->"}
      else
        {"", "<!-- local: runs the one OCI image in a krunvm/container; no secrets needed -->"}
      end

    """
    <!doctype html>
    <html lang="en"><head><meta charset="utf-8"><title>Deployment</title></head><body>
    #{body_note}
    <work-deploy
      engine-place="#{place}"
      tenancy-mode="single"
      storage="#{if place == "cloud", do: "s3", else: "local-fs"}"
      database="#{if place == "cloud", do: "postgres", else: "sqlite"}"
      auth="trusted"#{extra}>
    </work-deploy>
    </body></html>
    """
  end

  @doc "Parse the `<work-deploy>` element's attributes → `%{\"ENGINE_PLACE\" => …}` (uppercase keys)."
  def parse(html) when is_binary(html) do
    case Regex.run(~r/<work-deploy\b([^>]*)>/i, html) do
      [_, attrs] ->
        props =
          Regex.scan(~r/([a-zA-Z][\w-]*)\s*=\s*"([^"]*)"/, attrs)
          |> Map.new(fn [_, k, v] -> {k |> String.upcase() |> String.replace("-", "_"), v} end)

        {:ok, props}

      _ ->
        {:error, :no_work_deploy_element}
    end
  end

  @doc "Validate a parsed config → `:ok | {:error, [issue, …]}`. Coherence rules, not just enums."
  def validate(p) when is_map(p) do
    place = p["ENGINE_PLACE"] || "local"
    tenancy = p["TENANCY_MODE"] || "single"
    storage = p["STORAGE"] || "local-fs"
    database = p["DATABASE"] || "sqlite"
    auth = p["AUTH"] || "trusted"

    issues =
      []
      |> enum_check(place, @places, "ENGINE_PLACE")
      |> enum_check(tenancy, @tenancy, "TENANCY_MODE")
      |> enum_check(storage, @storage, "STORAGE")
      |> enum_check(database, @database, "DATABASE")
      |> enum_check(auth, @auth, "AUTH")
      |> add_if(tenancy == "multi" and database == "sqlite", "TENANCY_MODE: multi needs DATABASE: postgres (sqlite can't isolate tenants safely)")
      |> add_if(tenancy == "multi" and auth == "trusted", "TENANCY_MODE: multi needs real AUTH (betterauth|clerk|oidc) — `trusted` has no identity to isolate tenants by")
      |> add_if(place == "cloud" and auth == "trusted" and blank?(System.get_env("WB_PUBLIC_BEARER")), "ENGINE_PLACE: cloud + AUTH: trusted is an OPEN control plane — set WB_PUBLIC_BEARER in your deploy ENV, or use a real AUTH")
      |> add_if(auth != "trusted" and blank?(p["ISSUER"]), "AUTH: #{auth} needs an ISSUER (the token issuer / JWKS origin)")
      |> add_if(storage == "s3" and (blank?(p["STORAGE_BUCKET"]) or blank?(p["STORAGE_ENDPOINT"])), "STORAGE: s3 needs STORAGE_BUCKET + STORAGE_ENDPOINT")
      |> add_if(database == "postgres" and blank?(System.get_env("WB_DATABASE_URL")), "DATABASE: postgres needs WB_DATABASE_URL in your deploy ENV")
      |> Enum.reverse()

    if issues == [], do: :ok, else: {:error, issues}
  end

  @doc "The active place for a parsed config (\"local\" by default)."
  def place(p), do: p["ENGINE_PLACE"] || "local"

  defp enum_check(issues, value, allowed, key) do
    add_if(issues, value not in allowed, "#{key}: \"#{value}\" is not one of #{Enum.join(allowed, " | ")}")
  end

  defp add_if(issues, true, msg), do: [msg | issues]
  defp add_if(issues, false, _msg), do: issues
  defp blank?(v), do: v in [nil, ""]
end
