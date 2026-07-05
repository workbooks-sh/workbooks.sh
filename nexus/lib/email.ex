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
  The From address for `tenant` — sub-addressed (`agent+<tenant>@<domain>`) so a reply routes back to
  THAT tenant's inbox (see `ingest/2`); the plain default `email_from` for the nexus's own org.
  """
  def from_for(tenant) do
    cond do
      tenant in [nil, "", Nexus.Store.default_tenant()] -> Nexus.Config.email_from()
      d = Nexus.Config.email_domain() -> "agent+" <> to_string(tenant) <> "@" <> d
      true -> Nexus.Config.email_from()
    end
  end

  # The send-opt keys a reactive `email.send` effect may carry (string OR atom keys from a `.work` hook).
  @effect_keys ~w(to subject text html from from_name reply_to cc bcc provider)a

  @doc """
  Register the `email.send` effect on the reactive bus — the "richer sink" the `Nexus.Effects` `notify`
  moduledoc anticipates. Once installed, a `.work` hook can `run email.send to: … subject: … text: …`
  (or any `#event → hook → match` path). Called once at boot from `Nexus.Application`. Idempotent.
  """
  def install do
    Nexus.Effects.register("email.send", fn args, _event, _ctx ->
      m = Map.new(args)

      @effect_keys
      |> Enum.map(fn k -> {k, m[k] || m[to_string(k)]} end)
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> send()
    end)

    :ok
  end

  # ── Inbox (the receive half — durable, tenant-scoped, via Nexus.ControlPlane) ─────────────────────
  # Inbound mail (Cloudflare Email Routing → Worker → the ingress) lands here as `kind: "email"` records.
  # No compiled `resource` module needed: CP is the generic tenant-partitioned record store the rest of
  # the control plane already uses (integrations, events). A guest can never read another tenant's inbox.

  @inbox_kind "email"

  @doc """
  Store an inbound message in `tenant`'s inbox. `msg` (string/atom keys): `from`, `to`, `subject`,
  `text`/`html`, optional `message_id`, `in_reply_to`, `references`. Stamps `direction:"in"`,
  `status:"unread"`, `received_at`, and a `thread` key (reply root or normalized subject). `{:ok, record}`.
  """
  def deliver_inbound(tenant, msg) when is_binary(tenant) and is_map(msg) do
    m = Map.new(msg, fn {k, v} -> {to_string(k), v} end)
    id = blankish(m["message_id"]) || gen_id()

    attrs =
      Map.merge(m, %{
        "direction" => "in",
        "status" => "unread",
        "received_at" => System.os_time(:millisecond),
        "thread" => thread_key(m)
      })

    Nexus.ControlPlane.put(tenant, @inbox_kind, id, attrs)
  end

  @doc "List `tenant`'s inbox, newest first. `opts[:status]` (\"unread\"|\"read\"|\"archived\") / `opts[:thread]` filter."
  def inbox(tenant, opts \\ []) when is_binary(tenant) do
    Nexus.ControlPlane.list(tenant, @inbox_kind)
    |> Enum.reverse()
    |> filter_opt("status", opts[:status])
    |> filter_opt("thread", opts[:thread])
  end

  @doc "Read one message by id and mark it read. `{:ok, record} | {:error, :not_found}`."
  def read(tenant, id) when is_binary(tenant) and is_binary(id) do
    case Nexus.ControlPlane.get(tenant, @inbox_kind, id) do
      {:ok, _rec} -> mark(tenant, id, "read")
      _ -> {:error, :not_found}
    end
  end

  @doc "Set a message's status. `{:ok, record} | {:error, :not_found}`."
  def mark(tenant, id, status) when is_binary(status) do
    case Nexus.ControlPlane.get(tenant, @inbox_kind, id) do
      {:ok, rec} -> Nexus.ControlPlane.put(tenant, @inbox_kind, id, Map.put(rec, "status", status))
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Reply to an inbound message: sends to its `from`, prefixes `Re:`, threads via an `In-Reply-To` header,
  and marks the original read on success. `opts`: `:text`/`:html` body (+ any `send/1` opt). Reaches the
  outbound relay, so `{:error, :not_configured}` with no key.
  """
  def reply(tenant, id, opts \\ []) when is_binary(tenant) and is_binary(id) do
    case Nexus.ControlPlane.get(tenant, @inbox_kind, id) do
      {:ok, rec} ->
        send_opts =
          opts
          |> Map.new()
          |> Map.put(:to, rec["from"])
          |> Map.put(:subject, re_subject(rec["subject"]))
          |> Map.put_new(:headers, %{"In-Reply-To" => rec["message_id"] || id})

        result = send(send_opts)
        if match?({:ok, _}, result), do: mark(tenant, id, "read")
        result

      _ ->
        {:error, :not_found}
    end
  end

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

  @doc """
  Ingest an inbound message the CF Email Worker POSTed (MIME already parsed at the edge into clean JSON:
  `from`, `to`, `subject`, `text`/`html`, `message_id`, `in_reply_to`, `references`). Stores it in the
  recipient tenant's inbox and emits an `email.received` event so `#email.received` hooks fire (waking
  an agent). Recipient `local+<tenant>@domain` routes to `<tenant>`; else `opts[:tenant]` or the nexus's
  default org. `{:ok, record}`.
  """
  def ingest(payload, opts \\ []) when is_map(payload) do
    m = Map.new(payload, fn {k, v} -> {to_string(k), v} end)
    tenant = opts[:tenant] || tenant_for(m["to"]) || Nexus.Store.default_tenant()

    with {:ok, rec} <- deliver_inbound(tenant, m) do
      _ =
        Nexus.Events.emit(
          %{kind: "email.received", tenant: tenant, email_id: rec[:id],
            from: m["from"], subject: m["subject"], thread: rec["thread"]},
          tenant: tenant
        )

      {:ok, rec}
    end
  end

  # Recipient → tenant. Sub-addressed `local+<tenant>@domain` routes to `<tenant>`; otherwise nil so the
  # caller falls back to the nexus's own org. Keeps single-org simple, multi-tenant sub-addressing ready.
  defp tenant_for(to) when is_binary(to) do
    case Regex.run(~r/\+([a-z0-9_-]+)@/i, to) do
      [_, tag] -> tag
      _ -> nil
    end
  end

  defp tenant_for(_), do: nil

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
      |> put_some("headers", o[:headers])

    request("brevo", :post, ["v3", "smtp", "email"], body, o)
  end

  defp dispatch("smtp2go", from, to, o) do
    body =
      %{"sender" => sender_map("smtp2go", from, o[:from_name]), "to" => to, "subject" => o[:subject]}
      |> put_some("text_body", o[:text])
      |> put_some("html_body", o[:html])
      |> put_some("cc", List.wrap(o[:cc]))
      |> put_some("bcc", List.wrap(o[:bcc]))
      |> put_some("custom_headers", smtp2go_headers(o[:headers]))

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

  # SMTP2GO takes headers as a list of {header, value}; Brevo takes a plain map (passed through above).
  defp smtp2go_headers(h) when is_map(h) and map_size(h) > 0,
    do: for({k, v} <- h, do: %{"header" => to_string(k), "value" => to_string(v)})

  defp smtp2go_headers(_), do: nil

  # ── inbox helpers ────────────────────────────────────────────────────────────────────────────────
  defp gen_id, do: :crypto.strong_rand_bytes(9) |> Base.url_encode64()
  defp blankish(v) when v in [nil, ""], do: nil
  defp blankish(v), do: v
  defp filter_opt(recs, _key, nil), do: recs
  defp filter_opt(recs, key, val), do: Enum.filter(recs, &(&1[key] == to_string(val)))

  # Thread key: reply root (In-Reply-To / first Reference) if present, else the normalized subject.
  defp thread_key(m) do
    cond do
      is_binary(blankish(m["in_reply_to"])) -> m["in_reply_to"]
      is_binary(blankish(m["references"])) -> m["references"] |> String.split() |> List.first()
      is_binary(m["subject"]) -> normalize_subject(m["subject"])
      true -> "thread-" <> gen_id()
    end
  end

  defp normalize_subject(s),
    do: s |> to_string() |> String.replace(~r/^\s*(re|fwd?):\s*/i, "") |> String.trim() |> String.downcase()

  defp re_subject(s) do
    s = to_string(s)
    if String.match?(s, ~r/^\s*re:/i), do: s, else: "Re: " <> s
  end

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
