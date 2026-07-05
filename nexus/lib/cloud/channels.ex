defmodule Nexus.Cloud.Channels do
  @moduledoc """
  Cloud **phone channel** broker — provision a Telnyx number for a tenant's autopoet (text + call), run
  toll-free verification, and keep the number→tenant registry the inbound webhook resolves against.

  Mirrors the Fly/Composio brokers: neutral + no-op-safe (every verb degrades to `{:skip, reason}` when
  `TELNYX_API_KEY` is absent), the high-value token held server-side (`Nexus.Telnyx` via `Nexus.Secrets`,
  never a tenant machine), and the HTTP layer injectable via `opts[:http]`/`opts[:token]` so provisioning
  is unit-testable with no network.

  Registry: a provisioned number is written TWICE — a per-tenant `kind: "phone_number"` record (drives
  `list/1`, status, TF state) AND a row in a fixed global partition (`@registry_org`) keyed by the number,
  because the inbound webhook holds only a destination number and must answer "who owns +1855…?" without
  scanning every tenant. The global row carries only `{number, tenant}` — no tenant data crosses.
  """
  alias Nexus.Telnyx
  alias Nexus.ControlPlane, as: CP

  @kind "phone_number"
  @registry_org "_channels"

  @doc "Is the phone channel live on this nexus (a Telnyx key configured)?"
  def configured?, do: Telnyx.configured?()

  @doc "Search purchasable US toll-free numbers with SMS. `opts[:limit]` (default 10)."
  def available_numbers(opts \\ []) do
    guarded(opts, fn ->
      filters = %{
        "filter[phone_number_type]" => "toll_free",
        "filter[country_code]" => "US",
        "filter[features][]" => "sms",
        "filter[limit]" => opts[:limit] || 10
      }

      Telnyx.available_numbers([filters: filters] ++ pass(opts))
    end)
  end

  @doc """
  Provision `phone_number` for `tenant`: attach a messaging profile whose inbound webhook points at our
  ingress, order the number, and register number→tenant (per-tenant record + the global owner index).
  `{:ok, record} | {:error, reason} | {:skip, reason}`.
  """
  def provision(tenant, phone_number, opts \\ []) when is_binary(tenant) and is_binary(phone_number) do
    guarded(opts, fn ->
      webhook = opts[:webhook_url] || webhook_url()

      with {:ok, profile} <- Telnyx.create_messaging_profile("autopoet:" <> tenant, webhook, pass(opts)),
           profile_id when is_binary(profile_id) <- dig_id(profile),
           {:ok, _order} <- Telnyx.order_number(phone_number, [messaging_profile_id: profile_id] ++ pass(opts)) do
        rec = %{
          "number" => phone_number,
          "tenant" => tenant,
          "provider" => "telnyx",
          "messaging_profile_id" => profile_id,
          "status" => "provisioned",
          "tf_status" => "unverified",
          "webhook_url" => webhook
        }

        {:ok, _} = CP.put(@registry_org, "number_owner", phone_number, %{"number" => phone_number, "tenant" => tenant})
        CP.put(tenant, @kind, phone_number, rec)
      else
        nil -> {:error, :no_messaging_profile_id}
        {:error, e} -> {:error, e}
        {:skip, r} -> {:skip, r}
      end
    end)
  end

  @doc "The tenant's provisioned numbers, newest first."
  def list(tenant) when is_binary(tenant), do: CP.list(tenant, @kind) |> Enum.reverse()

  @doc "Resolve the tenant that owns `number` — the inbound webhook's number→tenant lookup. `nil` if unknown."
  def tenant_for_number(number) when is_binary(number) do
    case CP.get(@registry_org, "number_owner", number) do
      {:ok, %{"tenant" => t}} -> t
      _ -> nil
    end
  end

  @doc "Release a number — deregister it (per-tenant record + the global index). `{:ok, :released}`."
  def release(tenant, number) when is_binary(tenant) and is_binary(number) do
    CP.delete(tenant, @kind, number)
    CP.delete(@registry_org, "number_owner", number)
    {:ok, :released}
  end

  @doc """
  Submit a toll-free verification request. `body` is the Telnyx-shaped verification form (business info,
  use case, opt-in description, sample messages — the cloud owns that opinion). Stamps the returned
  verification id + `pending` status onto the number record. `{:ok, resp} | {:error, _} | {:skip, _}`.
  """
  def submit_verification(tenant, body, opts \\ []) when is_binary(tenant) and is_map(body) do
    guarded(opts, fn ->
      with {:ok, resp} <- Telnyx.tollfree_verification(body, pass(opts)) do
        vid = dig_id(resp)
        number = body["phone_number"] || body[:phone_number]
        if is_binary(vid) and is_binary(number), do: stamp_verification(tenant, number, vid, "pending")
        {:ok, resp}
      end
    end)
  end

  @doc "Fetch a toll-free verification's status. `{:ok, resp} | {:error, _} | {:skip, _}`."
  def verification_status(id, opts \\ []) when is_binary(id),
    do: guarded(opts, fn -> Telnyx.tollfree_verification_status(id, pass(opts)) end)

  @doc """
  Handle a VERIFIED inbound Telnyx event (the `/cloud/telnyx/webhook` route calls this only after the
  Ed25519 signature passes). For an inbound SMS (`message.received`) it resolves the destination number's
  owning tenant and emits an `sms.received` event so `#sms.received` hooks fire (waking that tenant's
  agent). Other event types are ignored. `{:ok, :emitted} | {:ok, :ignored}`.
  """
  def ingest_event(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, m} when is_map(m) -> ingest_event(m)
      _ -> {:ok, :ignored}
    end
  end

  def ingest_event(%{"data" => %{"event_type" => "message.received", "payload" => p}}) when is_map(p) do
    to = p |> Map.get("to", []) |> List.wrap() |> List.first() |> number_of()
    from = p |> Map.get("from") |> number_of()
    tenant = tenant_for_number(to || "") || Nexus.Store.default_tenant()

    _ =
      Nexus.Events.emit(
        %{kind: "sms.received", tenant: tenant, from: from, to: to, text: p["text"]},
        tenant: tenant
      )

    {:ok, :emitted}
  end

  def ingest_event(_), do: {:ok, :ignored}

  defp number_of(%{"phone_number" => n}) when is_binary(n), do: n
  defp number_of(_), do: nil

  # ── internals ────────────────────────────────────────────────────────────────────────────────────
  # Live when a key is configured OR a test injects a transport/token (so provisioning is testable offline).
  defp guarded(opts, fun) do
    if configured?() || opts[:token] || Keyword.has_key?(opts, :http),
      do: fun.(),
      else: {:skip, "phone channel not configured"}
  end

  defp pass(opts), do: Enum.filter([:http, :token], &Keyword.has_key?(opts, &1)) |> Enum.map(&{&1, opts[&1]})

  # Telnyx wraps created resources in {"data": {"id": …}}; tolerate a bare {"id": …}.
  defp dig_id(%{"data" => %{"id" => id}}) when is_binary(id), do: id
  defp dig_id(%{"id" => id}) when is_binary(id), do: id
  defp dig_id(_), do: nil

  defp stamp_verification(tenant, number, vid, status) do
    case CP.get(tenant, @kind, number) do
      {:ok, rec} -> CP.put(tenant, @kind, number, Map.merge(rec, %{"tf_verification_id" => vid, "tf_status" => status}))
      _ -> :ok
    end
  end

  defp webhook_url, do: (Nexus.Config.home() || "") <> "/cloud/telnyx/webhook"
end
