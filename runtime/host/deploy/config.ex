defmodule Workbooks.Deploy.Config do
  @moduledoc """
  A `deployment.org` — the ONE declarative description of a deployment. Two places
  (`ENGINE_PLACE: local|cloud`), two tenancy modes (`TENANCY_MODE: single|multi`),
  and BYOD backends (`STORAGE`, `DATABASE`) + the agent `PROFILE`. `wb deploy
  validate` checks coherence; `wb deploy apply` converges to it. File-based by
  design (no prompts); SECRETS (S3 keys, the Postgres DSN) come from the deploy
  ENV, never the file.

  Parsed with a hand-rolled `:PROPERTIES:` scan — NOT the OQL/org parser, never
  executed — so a deployment file is inert config, exactly as the descriptors
  in cli/deploy-kit/deployments/ document.
  """

  @places ~w(local cloud)
  @tenancy ~w(single multi)
  @storage ~w(local-fs s3)
  @database ~w(sqlite postgres)
  @auth ~w(trusted betterauth clerk oidc)

  @doc "Parse a deployment.org → the property map (string keys)."
  def parse(path) do
    case File.read(path) do
      {:ok, body} -> {:ok, parse_props(body)}
      {:error, e} -> {:error, "cannot read #{path}: #{:file.format_error(e)}"}
    end
  end

  defp parse_props(body) do
    body
    |> String.split("\n")
    |> Enum.reduce({false, %{}}, fn line, {in?, acc} ->
      t = String.trim(line)

      cond do
        String.upcase(t) == ":PROPERTIES:" -> {true, acc}
        String.upcase(t) == ":END:" -> {false, acc}
        in? ->
          case Regex.run(~r/^:([A-Za-z_]+):\s+(.*\S)\s*$/, t) do
            [_, k, v] -> {true, Map.put(acc, String.upcase(k), String.trim(v))}
            _ -> {true, acc}
          end

        true ->
          {in?, acc}
      end
    end)
    |> elem(1)
  end

  @doc """
  Coherence-check a parsed config → `:ok` or `{:error, [issues]}`. Encodes the
  honest combos: multi-tenant on sqlite serializes every tenant through one writer
  (error); s3 needs its bucket/endpoint; postgres + s3 need their SECRET in env.
  """
  def validate(p) do
    place = p["ENGINE_PLACE"]
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
      |> add_if(tenancy == "multi" and database == "sqlite",
        "TENANCY_MODE: multi on DATABASE: sqlite serializes every tenant through one writer — set DATABASE: postgres")
      |> add_if(tenancy == "multi" and auth == "trusted",
        "TENANCY_MODE: multi needs real AUTH (betterauth|clerk|oidc) — `trusted` has no identity to isolate tenants by")
      |> add_if(auth != "trusted" and blank?(p["ISSUER"]),
        "AUTH: #{auth} needs an ISSUER (the token issuer / JWKS origin)")
      |> add_if(storage == "s3" and (blank?(p["STORAGE_BUCKET"]) or blank?(p["STORAGE_ENDPOINT"])),
        "STORAGE: s3 needs STORAGE_BUCKET + STORAGE_ENDPOINT in the file")
      |> add_if(storage == "s3" and (env_blank?("WB_S3_KEY") or env_blank?("WB_S3_SECRET")),
        "STORAGE: s3 needs WB_S3_KEY + WB_S3_SECRET in your deploy ENV (secrets, not the file)")
      |> add_if(database == "postgres" and env_blank?("WB_DATABASE_URL"),
        "DATABASE: postgres needs WB_DATABASE_URL in your deploy ENV (the DSN is a secret)")

    if issues == [], do: :ok, else: {:error, Enum.reverse(issues)}
  end

  @doc """
  The ENGINE env a config implies — non-secret axes from the file + SECRETS
  forwarded from the deploy ENV (never echoed). This is exactly what the runtime
  reads: WB_STORAGE / WB_S3_* / WB_DATABASE_URL / WB_TENANCY_MODE / WB_PROFILE_DIR.
  """
  def to_env(p) do
    base = %{
      "WB_TENANCY_MODE" => p["TENANCY_MODE"] || "single",
      "WB_STORAGE" => storage_env(p["STORAGE"] || "local-fs")
    }

    base
    |> put_present("WB_APP_NAME", p["APP"])
    |> put_present("WB_S3_ENDPOINT", p["STORAGE_ENDPOINT"])
    |> put_present("WB_S3_BUCKET", p["STORAGE_BUCKET"])
    |> put_present("WB_S3_REGION", p["STORAGE_REGION"])
    |> put_present("WB_PROFILE_DIR", p["PROFILE"])
    |> put_present("WB_REGION", p["REGION"])
    |> auth_env(p)
    |> forward_secret("WB_S3_KEY")
    |> forward_secret("WB_S3_SECRET")
    |> forward_secret("WB_DATABASE_URL")
    |> forward_secret("OPENROUTER_API_KEY")
  end

  # AUTH/ISSUER → the runtime's Guardian env: WB_AUTH_ISSUER + the JWKS endpoint
  # (RS256 verification). `trusted` is the no-real-auth path (single-tenant). The
  # JWKS path is derived per provider (BetterAuth is non-standard); an explicit
  # JWKS_URL property overrides.
  defp auth_env(map, p) do
    auth = p["AUTH"] || "trusted"
    issuer = p["ISSUER"]

    if auth == "trusted" or blank?(issuer) do
      map
    else
      jwks = p["JWKS_URL"] || derive_jwks(auth, issuer)

      map
      |> Map.put("WB_AUTH_ISSUER", issuer)
      |> put_present("WB_JWKS_URL", jwks)
    end
  end

  defp derive_jwks("betterauth", issuer), do: String.trim_trailing(issuer, "/") <> "/api/auth/jwks"
  defp derive_jwks(_oidc, issuer), do: String.trim_trailing(issuer, "/") <> "/.well-known/jwks.json"

  @doc "Which place a config targets (`local` | `cloud`)."
  def place(p), do: p["ENGINE_PLACE"]

  @doc "The cloud provider recipe for a cloud config (PROVIDER property, default fly)."
  def provider(p), do: p["PROVIDER"] || "fly"

  @doc "A one-line human summary of the deployment shape."
  def summary(p) do
    "#{place(p)} · #{p["TENANCY_MODE"] || "single"}-tenant · storage=#{p["STORAGE"] || "local-fs"} · db=#{p["DATABASE"] || "sqlite"}" <>
      if(place(p) == "cloud", do: " · provider=#{provider(p)}", else: "")
  end

  # ---- helpers ---------------------------------------------------------------
  defp storage_env("local-fs"), do: "local"
  defp storage_env("s3"), do: "s3"
  defp storage_env(other), do: other

  defp enum_check(issues, val, allowed, name) do
    add_if(issues, val == nil or val not in allowed, "#{name} must be one of #{Enum.join(allowed, "|")} (got #{inspect(val)})")
  end

  defp add_if(issues, true, msg), do: [msg | issues]
  defp add_if(issues, _false, _msg), do: issues

  defp blank?(v), do: v == nil or String.trim(v) == ""
  defp env_blank?(k), do: blank?(System.get_env(k))

  defp put_present(map, _k, nil), do: map
  defp put_present(map, k, v), do: if(blank?(v), do: map, else: Map.put(map, k, v))

  defp forward_secret(map, k) do
    case System.get_env(k) do
      nil -> map
      "" -> map
      v -> Map.put(map, k, v)
    end
  end
end
