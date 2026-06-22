defmodule Nexus.Polar do
  @moduledoc """
  Polar billing seam — checkout creation + Standard-Webhooks signature verification.

  Polar is a merchant-of-record (it carries the sales-tax/VAT burden). We use it for two flows in the
  cloud product:

    * **Onboarding subscription** — a customer pays for their nexus tier (Starter/Team/Scale). One Polar
      *subscription* product per tier.
    * **Inference credit top-ups** — an arbitrary-USD purchase of Workbooks Inference credit, modelled
      as a Polar one-time *custom-amount* product. Because the checkout is bound to the org via
      `external_customer_id`, Polar reuses the **card on file** from the first purchase — subsequent
      top-ups are one click.

  THE LINE: this module carries only generic mechanism. The access token + webhook secret are SECRETS
  (`Nexus.Secrets`, injected at deploy — never in source). The Polar server (sandbox|production) and the
  product UUIDs are OUR cloud's CONFIG (`Nexus.Config`, the deploy block) — another operator brings
  their own. Nothing of our business is baked into `lib/`.

  HTTP via `:httpc` (no extra dep), matching `Nexus.GitHub` / `Nexus.Llm`.
  """

  @doc "True when a Polar access token is configured (the feature is live)."
  def configured?, do: is_binary(token())

  defp token, do: Nexus.Secrets.get("POLAR_ACCESS_TOKEN")

  # Sandbox by default — production is opt-in via `deploy polar-server="production"`. Polar's sandbox is
  # a fully isolated environment (separate data, tokens, products) for wiring + testing.
  defp base do
    case Nexus.Config.polar_server() do
      "production" -> "https://api.polar.sh"
      _ -> "https://sandbox-api.polar.sh"
    end
  end

  @doc """
  Create a Polar checkout session.

  `opts`:
    * `:products` — list of Polar product UUIDs (required, ≥1).
    * `:external_customer_id` — our stable customer id (the org/tenant). Binds the checkout to a Polar
      customer so the card on file is reused on later purchases.
    * `:customer_email`, `:customer_name` — prefill.
    * `:success_url` — where Polar returns the customer after payment.
    * `:metadata` — string→string map carried back on the webhook (we stamp `tenant`/`purpose`/`amount`).
    * `:amount` — cents, custom-amount products ONLY (the credit top-up flow).

  Returns `{:ok, %{url: ..., id: ...}}` | `{:error, reason}`. `{:error, :not_configured}` when no token.
  """
  def create_checkout(opts) when is_list(opts) or is_map(opts) do
    opts = Map.new(opts)
    products = opts[:products] || []

    cond do
      is_nil(token()) ->
        {:error, :not_configured}

      products == [] ->
        {:error, :no_products}

      true ->
        body =
          %{products: products}
          |> put_some(:external_customer_id, opts[:external_customer_id])
          |> put_some(:customer_email, opts[:customer_email])
          |> put_some(:customer_name, opts[:customer_name])
          |> put_some(:success_url, opts[:success_url])
          |> put_some(:metadata, stringify_metadata(opts[:metadata]))
          |> put_some(:amount, opts[:amount])

        case post("/v1/checkouts/", body) do
          {:ok, %{"url" => url} = resp} -> {:ok, %{url: url, id: resp["id"]}}
          {:ok, resp} -> {:error, {:no_url, resp}}
          err -> err
        end
    end
  end

  @doc """
  Verify an inbound Polar webhook using the **Standard Webhooks** scheme against `POLAR_WEBHOOK_SECRET`.

  Headers: `webhook-id`, `webhook-timestamp`, `webhook-signature`. The signed content is
  `"<id>.<timestamp>.<raw_body>"`; the signature is base64(HMAC-SHA256(secret, content)). The
  `webhook-signature` header is a space-delimited list of `v1,<base64sig>` — any match passes. The secret
  may be a `whsec_<base64>` string (base64-decoded to key bytes) or raw. Constant-time compare. Fails
  closed (false) when no secret is configured.
  """
  def verify_webhook(raw_body, headers) when is_binary(raw_body) and is_map(headers) do
    with secret when is_binary(secret) <- Nexus.Secrets.get("POLAR_WEBHOOK_SECRET"),
         id when is_binary(id) <- headers["webhook-id"],
         ts when is_binary(ts) <- headers["webhook-timestamp"],
         sig_header when is_binary(sig_header) <- headers["webhook-signature"] do
      key = secret_key(secret)
      signed = "#{id}.#{ts}.#{raw_body}"
      expected = :crypto.mac(:hmac, :sha256, key, signed) |> Base.encode64()

      sig_header
      |> String.split(" ", trim: true)
      |> Enum.any?(fn part ->
        case String.split(part, ",", parts: 2) do
          [_ver, sig] -> Plug.Crypto.secure_compare(expected, sig)
          [sig] -> Plug.Crypto.secure_compare(expected, sig)
          _ -> false
        end
      end)
    else
      _ -> false
    end
  end

  def verify_webhook(_, _), do: false

  # whsec_<base64> → decoded key bytes; plain base64 → decoded; otherwise the raw string bytes.
  defp secret_key("whsec_" <> b64), do: Base.decode64(b64) |> case(do: ({:ok, k} -> k; _ -> b64))
  defp secret_key(s) do
    case Base.decode64(s) do
      {:ok, k} -> k
      _ -> s
    end
  end

  # ── HTTP ────────────────────────────────────────────────────────────────────────────────────────
  defp post(path, body) do
    url = String.to_charlist(base() <> path)

    headers = [
      {~c"authorization", String.to_charlist("Bearer #{token()}")},
      {~c"accept", ~c"application/json"},
      {~c"user-agent", ~c"workbooks-nexus"}
    ]

    request = {url, headers, ~c"application/json", Jason.encode!(body)}

    case :httpc.request(:post, request, [{:timeout, 20_000}], body_format: :binary) do
      {:ok, {{_, status, _}, _h, resp}} when status in 200..299 ->
        {:ok, (resp == "" && %{}) || Jason.decode!(resp)}

      {:ok, {{_, status, _}, _h, resp}} ->
        {:error, {:http, status, resp}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp put_some(map, _k, nil), do: map
  defp put_some(map, _k, ""), do: map
  defp put_some(map, k, v), do: Map.put(map, k, v)

  # Polar metadata values must be strings (≤500 chars). Coerce numbers/atoms.
  defp stringify_metadata(nil), do: nil

  defp stringify_metadata(m) when is_map(m) do
    Map.new(m, fn {k, v} -> {to_string(k), v |> to_string() |> String.slice(0, 500)} end)
  end
end
