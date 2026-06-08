defmodule Workbooks.Publish.Config do
  @moduledoc """
  A `publish.org` — the declarative description of where a workbook gets deployed.
  One file per workbook site; `wb publish validate` checks it; `wb publish apply`
  renders + ships it. Mirrors the shape of `Deploy.Config` (same `:PROPERTIES:`
  parser, same validate/to_env pattern) so both feel like one system.

  Parsed with a hand-rolled `:PROPERTIES:` scan — NOT the OQL/org parser — so a
  publish file is inert config.
  """

  @targets ~w(cloudflare-pages gh-pages self-hosted)

  @doc "Parse a publish.org → the property map (string keys)."
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

  @doc "Coherence-check a parsed config → `:ok` or `{:error, [issues]}`."
  def validate(p) do
    target = p["PUBLISH_TARGET"]

    issues =
      []
      |> enum_check(target, @targets, "PUBLISH_TARGET")
      |> add_if(target == "cloudflare-pages" and blank?(p["PUBLISH_PROJECT"]),
        "PUBLISH_TARGET: cloudflare-pages needs PUBLISH_PROJECT (the Cloudflare Pages project name)")
      |> add_if(target == "gh-pages" and blank?(p["PUBLISH_PROJECT"]),
        "PUBLISH_TARGET: gh-pages needs PUBLISH_PROJECT (the GitHub repo, e.g. org/repo)")
      |> add_if(target == "self-hosted" and blank?(p["PUBLISH_URL"]),
        "PUBLISH_TARGET: self-hosted needs PUBLISH_URL (the runtime base URL)")

    warnings = secret_warnings(p)
    all = Enum.reverse(issues) ++ warnings

    if all == [], do: :ok, else: {:error, all}
  end

  # Warn on property values that look like secrets — hex IDs, tokens, keys.
  # These belong in env vars, not org files.
  defp secret_warnings(p) do
    secret_key? = fn k ->
      Enum.any?(~w(TOKEN KEY SECRET ACCOUNT PASSWORD CREDENTIAL), &String.ends_with?(k, &1))
    end

    hex_id? = fn v -> Regex.match?(~r/^[a-f0-9]{20,}$/i, to_string(v)) end

    Enum.flat_map(p, fn {k, v} ->
      cond do
        secret_key?.(k) ->
          ["#{k} looks like a secret — use an env var instead of storing it in publish.org"]
        hex_id?.(v) ->
          ["#{k}: value looks like a hex ID or token — use an env var if it is sensitive"]
        true ->
          []
      end
    end)
  end

  @doc "One-line human summary of the publish shape."
  def summary(p) do
    target = p["PUBLISH_TARGET"] || "?"
    domain = p["PUBLISH_DOMAIN"] || p["PUBLISH_PROJECT"] || "?"
    "target=#{target} · #{domain}"
  end

  @doc "The publish target atom."
  def target(p), do: p["PUBLISH_TARGET"]

  @doc "The title to use in the rendered HTML (falls back to project name)."
  def title(p), do: p["PUBLISH_TITLE"] || p["PUBLISH_PROJECT"] || "Workbook"

  # ---- helpers ---------------------------------------------------------------
  defp enum_check(issues, val, allowed, name) do
    add_if(issues, val == nil or val not in allowed,
      "#{name} must be one of #{Enum.join(allowed, "|")} (got #{inspect(val)})")
  end

  defp add_if(issues, true, msg), do: [msg | issues]
  defp add_if(issues, _false, _msg), do: issues

  defp blank?(v), do: v == nil or String.trim(v) == ""
end
