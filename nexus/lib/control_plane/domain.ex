defmodule Nexus.ControlPlane.Domain do
  @moduledoc """
  Custom domains for a paid org's nexus — "share from your own domain instead of
  ours". The default share wrapper is `<nexus>.fly.dev` (our domain of record on
  top of the tenant's Fly machine); a custom domain REPLACES that wrapper with the
  owner's domain on the same machine.

  Two gates keep the system untaintable:

    1. **Paid tier only** — `Nexus.Pricing.domains?/1` (Team and up). Starter can't bind.
    2. **Owner verification** — a random `wb-verify` token the owner must publish as a
       TXT record at `_workbooks-challenge.<host>` before we'll touch their domain.
       Until the TXT matches, the domain sits `pending` and no cert is requested.

  Plus **global uniqueness**: a host can be bound by at most one org (a direct table
  scan — the one legitimate cross-org read, and it only reveals taken/free, never another
  tenant's data), so org B can't hijack a host org A already owns.

  Once verified we ask Fly to provision a LetsEncrypt cert on the tenant's nexus app
  (`Nexus.Fly.add_certificate/3`) and hand back the DNS target the owner CNAMEs their
  domain at. Records live at the tenant-scoped key `{org, :domain, id}` — same isolation
  as every other control-plane row.
  """
  alias Nexus.ControlPlane, as: CP
  alias Nexus.ControlPlane.Store
  alias Nexus.Pricing

  @challenge_prefix "_workbooks-challenge."

  @doc """
  Begin binding `host` to the org's nexus. Refuses unless the org's tier allows
  custom domains, the host is well-formed, and no other org already owns it. Returns
  `{:ok, view}` with the TXT challenge + CNAME target the owner must publish.
  """
  def add(org, host, _opts \\ []) do
    host = normalize(host)

    with :ok <- check_host(host),
         {:ok, nx} <- nexus(org),
         :ok <- check_tier(nx),
         :ok <- check_unique(org, host) do
      id = "dom_" <> rand()

      attrs = %{
        host: host,
        status: "pending",
        verify_token: "wb-verify=" <> rand(),
        nexus_id: nx.id,
        fly_app: nx[:fly_app] || ("nexus-" <> nx.id),
        dns_target: target(nx),
        created_at: now(),
        verified_at: nil
      }

      {:ok, rec} = CP.put(org, :domain, id, attrs)
      {:ok, view(rec)}
    end
  end

  @doc "List the org's custom domains (redacted views — never the raw token of others)."
  def list(org), do: Enum.map(CP.list(org, :domain), &view/1)

  def get(org, id) do
    case CP.get(org, :domain, id) do
      {:ok, rec} -> {:ok, view(rec)}
      err -> err
    end
  end

  @doc """
  Verify ownership: resolve the TXT challenge at `_workbooks-challenge.<host>` and,
  on a match, request the Fly cert for the tenant's nexus app. Moves the record to
  `active` (cert requested) and records `dns_validation` (what Fly wants pointed where).
  """
  def verify(org, id, opts \\ []) do
    resolver = Keyword.get(opts, :resolver, &resolve_txt/1)
    fly = Keyword.get(opts, :fly, Nexus.Fly)

    with {:ok, rec} <- CP.get(org, :domain, id) do
      records = resolver.(@challenge_prefix <> rec.host)

      cond do
        rec.verify_token in records ->
          updates = %{status: "active", verified_at: now()} |> Map.merge(request_cert(fly, rec, opts))
          {:ok, rec2} = CP.update(org, :domain, id, updates)
          {:ok, view(rec2)}

        true ->
          {:error, :txt_not_found}
      end
    end
  end

  @doc "Remove a custom domain — drops the Fly cert, then the record."
  def remove(org, id, opts \\ []) do
    fly = Keyword.get(opts, :fly, Nexus.Fly)
    cf = Keyword.get(opts, :cloudflare, Nexus.Cloudflare)

    case CP.get(org, :domain, id) do
      {:ok, rec} ->
        if rec[:status] == "active" do
          # Undo whichever cert provider issued it (default fly for legacy records w/o a provider tag).
          case rec[:provider] do
            "cloudflare" -> if rec[:cf_hostname_id], do: cf.delete_custom_hostname(rec.cf_hostname_id, opts)
            _ -> fly.remove_certificate(rec.fly_app, rec.host, opts)
          end
        end

        :ok = CP.delete(org, :domain, id)
        :ok

      err ->
        err
    end
  end

  # ── internals ────────────────────────────────────────────────────────────────────────────────
  # Issue the cert for a verified host. PREFER Cloudflare-for-SaaS custom hostnames when configured (the
  # cheap, no-Fly-cert, edge-TLS path); otherwise fall back to a per-app Fly LetsEncrypt cert. The choice
  # is recorded as `provider` so removal undoes the right one.
  defp request_cert(fly, rec, opts) do
    cf = Keyword.get(opts, :cloudflare, Nexus.Cloudflare)

    if cf.saas_ready?(opts) do
      case cf.create_custom_hostname(rec.host, opts) do
        {:ok, ch} ->
          %{provider: "cloudflare", cf_hostname_id: ch["id"], cert_status: get_in(ch, ["ssl", "status"])}

        {:skip, _} ->
          request_fly_cert(fly, rec, opts)

        {:error, reason} ->
          %{status: "verified", cert_error: inspect(reason)}
      end
    else
      request_fly_cert(fly, rec, opts)
    end
  end

  defp request_fly_cert(fly, rec, opts) do
    case fly.add_certificate(rec.fly_app, rec.host, opts) do
      {:ok, body} ->
        cert = get_in(body, ["data", "addCertificate", "certificate"]) || %{}
        %{provider: "fly", dns_validation: %{target: cert["dnsValidationTarget"], hostname: cert["dnsValidationHostname"]}}

      {:error, reason} ->
        # Verification succeeded but Fly couldn't issue — keep it verified, surface the cert error.
        %{status: "verified", cert_error: inspect(reason)}
    end
  end

  defp check_tier(nx) do
    if Pricing.domains?(nx[:plan]), do: :ok, else: {:error, :tier_locked}
  end

  defp nexus(org) do
    case CP.list(org, :nexus) do
      [nx | _] -> {:ok, nx}
      [] -> {:error, :no_nexus}
    end
  end

  # CNAME the owner points their host at. With Cloudflare-for-SaaS configured this is the single shared
  # fallback origin (CF terminates TLS at its edge → our Fly origin); otherwise it's the tenant's Fly app
  # on our domain of record.
  defp target(nx) do
    Nexus.Config.cf_custom_hostname_origin() ||
      "#{nx[:fly_app] || "nexus-" <> nx.id}.fly.dev"
  end

  defp check_host(host) do
    cond do
      host == "" -> {:error, :invalid_host}
      not Regex.match?(~r/^[a-z0-9.-]+\.[a-z]{2,}$/, host) -> {:error, :invalid_host}
      Enum.any?(Nexus.Config.reserved_hosts(), &String.contains?(host, &1)) -> {:error, :reserved_host}
      true -> :ok
    end
  end

  # Global uniqueness — scan every org's :domain rows for this host. The ONLY cross-org
  # read in the control plane, and it leaks nothing but taken/free.
  defp check_unique(_org, host) do
    taken? =
      Store.list_kind(:domain)
      |> Enum.any?(fn rec -> rec[:host] == host end)

    if taken?, do: {:error, :host_taken}, else: :ok
  end

  defp resolve_txt(name) do
    name
    |> to_charlist()
    |> :inet_res.lookup(:in, :txt)
    |> Enum.map(fn parts -> parts |> List.flatten() |> List.to_string() end)
  rescue
    _ -> []
  end

  defp normalize(host) when is_binary(host),
    do: host |> String.trim() |> String.downcase() |> String.trim_leading("https://") |> String.trim_leading("http://") |> String.split("/") |> List.first()

  defp normalize(_), do: ""

  defp view(rec) do
    %{
      id: rec[:id],
      host: rec.host,
      status: rec[:status] || "pending",
      verify: %{type: "TXT", name: @challenge_prefix <> rec.host, value: rec[:verify_token]},
      cname: %{name: rec.host, target: rec[:dns_target]},
      provider: rec[:provider],
      cert_status: rec[:cert_status],
      dns_validation: rec[:dns_validation],
      cert_error: rec[:cert_error],
      created_at: rec[:created_at],
      verified_at: rec[:verified_at]
    }
  end

  defp rand, do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  defp now, do: System.system_time(:second)
end
