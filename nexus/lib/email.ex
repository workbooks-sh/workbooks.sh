defmodule Nexus.Email do
  @moduledoc """
  The neutral **outbound email seam** — send mail as `agent@agents.<domain>` through a pluggable relay,
  the send half of the agent-email channel (inbound is Cloudflare Email Routing → a CF Email Worker →
  the `/cloud/email/inbound` ingress; DNS for both is written by `Nexus.Cloudflare`).

  Mirrors `Nexus.Telnyx`/`Nexus.Cloudflare` exactly: a fixed host **per provider** (never caller input —
  the SSRF floor), the API key added ONLY inside the `:httpc` transport (never in the pure request shape,
  a log line, an error tuple, or a returned value), TLS verify_peer + pinned SNI, capped response body,
  and an injectable `opts[:http]` seam so request construction is unit-testable with no network.

  **Provider is config, not code.** `Nexus.Config.email_provider/0` (deploy attr `email-provider`) selects
  the adapter; the same `send/1` call works across relays, so moving Brevo → SMTP2GO → SES is a `.work`
  flip, not a rewrite. The ONE key resolves through `Nexus.Secrets` as `EMAIL_API_KEY` (broker pattern,
  like `TELNYX_API_KEY`). With no key `configured?/0` is false and `send/1` returns `{:error, :not_configured}`.

  Adapters (all real HTTP send APIs — no SMTP socket, no `:gen_smtp` dep):
    * `"brevo"`   — POST https://api.brevo.com/v3/smtp/email   (header `api-key`)   — 300/day free.
    * `"smtp2go"` — POST https://api.smtp2go.com/v3/email/send (header `x-smtp2go-api-key`) — 1k/mo free.

  SES (and any other relay) slots in as another `dispatch/4` clause behind the same seam.

  Returns `{:ok, result} | {:error, reason}`; never raises.
  """

  # provider → {fixed api host, pinned SNI charlist}. Caller-supplied provider names can ONLY select
  # from this table (unknown → {:error, {:unknown_provider, _}}), so the host is never attacker-chosen.
  @hosts %{
    "brevo" => {"https://api.brevo.com", ~c"api.brevo.com"},
    "smtp2go" => {"https://api.smtp2go.com", ~c"api.smtp2go.com"}
  }

  @max_body_bytes 1024 * 1024

  @doc "The relay providers this seam can send through."
  def providers, do: Map.keys(@hosts)

  @doc "True when an email relay key is configured (the outbound email channel is live)."
  def configured?, do: Nexus.Secrets.has?("EMAIL_API_KEY")

  @doc """
  Send an email through the configured relay. `opts` (keyword/map):

    * `:to`       — recipient email, or a list of them (required)
    * `:subject`  — required
    * `:text` and/or `:html` — body (at least one required)
    * `:from`     — sender address (defaults to `Nexus.Config.email_from/0`, e.g. `agent@agents.<domain>`)
    * `:from_name`, `:reply_to`, `:cc`, `:bcc` — optional
    * `:provider` — override `Nexus.Config.email_provider/0`
    * `:token` / `:http` — test/override seams

  `{:error, :not_configured}` with no key; `{:error, :missing_fields | :missing_from | :missing_body}`
  when required parts are absent.
  """
  def send(opts) do
    o = Map.new(opts)
    provider = to_string(o[:provider] || Nexus.Config.email_provider())
    from = o[:from] || Nexus.Config.email_from()
    to = List.wrap(o[:to]) |> Enum.reject(&(&1 in [nil, ""]))

    cond do
      not (configured?() or is_binary(o[:token])) -> {:error, :not_configured}
      to == [] or o[:subject] in [nil, ""] -> {:error, :missing_fields}
      from in [nil, ""] -> {:error, :missing_from}
      o[:text] in [nil, ""] and o[:html] in [nil, ""] -> {:error, :missing_body}
      true -> dispatch(provider, from, to, o)
    end
  end

  # ── Adapters (pure body construction; network-free) ──────────────────────────────────────────────

  defp dispatch("brevo", from, to, o) do
    body =
      %{
        "sender" => sender_map("brevo", from, o[:from_name]),
        "to" => Enum.map(to, &%{"email" => &1}),
        "subject" => o[:subject]
      }
      |> put_some("textContent", o[:text])
      |> put_some("htmlContent", o[:html])
      |> put_some("replyTo", o[:reply_to] && %{"email" => o[:reply_to]})
      |> put_some("cc", email_list(o[:cc]))
      |> put_some("bcc", email_list(o[:bcc]))

    request("brevo", :post, ["v3", "smtp", "email"], body, o)
  end

  defp dispatch("smtp2go", from, to, o) do
    body =
      %{"sender" => sender_map("smtp2go", from, o[:from_name]), "to" => to, "subject" => o[:subject]}
      |> put_some("text_body", o[:text])
      |> put_some("html_body", o[:html])
      |> put_some("cc", List.wrap(o[:cc]))
      |> put_some("bcc", List.wrap(o[:bcc]))

    request("smtp2go", :post, ["v3", "email", "send"], body, o)
  end

  defp dispatch(other, _from, _to, _o), do: {:error, {:unknown_provider, other}}

  # Brevo wants a `{email, name}` object; SMTP2GO wants an RFC-5322 string.
  defp sender_map("brevo", email, name) when is_binary(name) and name != "", do: %{"email" => email, "name" => name}
  defp sender_map("brevo", email, _), do: %{"email" => email}
  defp sender_map("smtp2go", email, name) when is_binary(name) and name != "", do: name <> " <" <> email <> ">"
  defp sender_map("smtp2go", email, _), do: email

  defp email_list(nil), do: nil
  defp email_list(v), do: v |> List.wrap() |> Enum.map(&%{"email" => &1})

  defp put_some(map, _k, nil), do: map
  defp put_some(map, _k, ""), do: map
  defp put_some(map, _k, []), do: map
  defp put_some(map, k, v), do: Map.put(map, k, v)

  # ── request: construct + dispatch + map (key added only in the transport) ────────────────────────

  defp request(provider, method, segments, body, o) do
    {host, sni} = Map.fetch!(@hosts, provider)
    url = host <> "/" <> Enum.join(segments, "/")
    headers = [{"accept", "application/json"}, {"content-type", "application/json"}]
    encoded = Jason.encode!(body)
    key = o[:token] || Nexus.Secrets.get("EMAIL_API_KEY") || ""
    http = o[:http] || (&do_request(&1, &2, &3, &4, provider, key, sni))

    case http.(method, url, headers, encoded) do
      {:ok, {status, resp}} when status in 200..299 -> {:ok, decode(resp)}
      {:ok, {status, resp}} -> {:error, {status, decode(resp)}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Real HTTP via :httpc. The relay's auth header (provider-specific NAME) is added HERE only — never in
  # the pure request the injected seam sees. TLS verified + SNI-pinned so the key can't be MITM-stolen.
  defp do_request(method, url, headers, body, provider, key, sni) do
    :inets.start()
    :ssl.start()

    headers = [auth_header(provider, key) | headers]
    hh = Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)
    req = {to_charlist(url), hh, ~c"application/json", body}

    o = [
      timeout: 20_000,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        server_name_indication: sni,
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]

    case :httpc.request(method, req, o, body_format: :binary) do
      {:ok, {{_, code, _}, _h, resp}} -> {:ok, {code, cap(resp)}}
      {:error, e} -> {:error, inspect(e)}
    end
  end

  defp auth_header("brevo", key), do: {"api-key", key}
  defp auth_header("smtp2go", key), do: {"x-smtp2go-api-key", key}

  defp cap(bin) when is_binary(bin) and byte_size(bin) > @max_body_bytes, do: binary_part(bin, 0, @max_body_bytes)
  defp cap(bin), do: bin

  defp decode(""), do: %{}

  defp decode(bin) when is_binary(bin) do
    case Jason.decode(bin) do
      {:ok, v} -> v
      _ -> bin
    end
  end

  defp decode(other), do: other
end
