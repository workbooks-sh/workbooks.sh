defmodule Nexus.Inference.Pricing do
  @moduledoc """
  Runtime model price registry — USD per **1M tokens**, `{input, output}`.

  Read by the money boundary (`Nexus.Llm.complete` → `Nexus.Inference.Admission.cost/2`) so EVERY paid
  call can be metered from one price source, including providers (Cloudflare Workers AI) that DON'T return
  a `cost` field and must be priced from token counts.

  Populated two ways, both real-time (no doc-page crawl):
    * **Cloudflare** — this GenServer fetches the official Workers AI models API
      (`/accounts/{acct}/ai/models/search`), which returns authoritative per-model `{price, unit}` pricing,
      on boot and every 12h. Authenticated with the `CF_AIG_TOKEN` we already hold.
    * **Other providers** — the cloud catalog (`server.work`) calls `put_all/1` with what it fetched
      (models.dev), and OpenRouter reports real `cost` per call, so those don't depend on this registry.
  """
  use GenServer

  @pt {__MODULE__, :rates}
  @refresh_ms 12 * 60 * 60 * 1000

  # ── registry (persistent_term — callable from ANY process, incl. the money boundary) ────────────────

  @doc """
  Register prices from a catalog: maps with `:id`/`"id"` and `:price_in`/`:price_out` (USD per 1M tokens;
  either key form). Idempotent + cheap — only writes `persistent_term` when the table actually changes.
  """
  @spec put_all([map]) :: :ok
  def put_all(models) when is_list(models) do
    incoming =
      for m <- models, id = m[:id] || m["id"], is_binary(id), reduce: %{} do
        acc ->
          pin = num(m[:price_in] || m["price_in"])
          pout = num(m[:price_out] || m["price_out"])
          if is_nil(pin) and is_nil(pout), do: acc, else: Map.put(acc, id, {pin, pout})
      end

    existing = :persistent_term.get(@pt, %{})
    merged = Map.merge(existing, incoming)
    if merged != existing, do: :persistent_term.put(@pt, merged)
    :ok
  end

  def put_all(_), do: :ok

  @doc "Blended USD/1M-token rate (mean of input+output) for a model id, matching either gateway id form."
  @spec rate(String.t() | nil) :: float | nil
  def rate(model) when is_binary(model) do
    rates = :persistent_term.get(@pt, %{})

    case rates[model] || rates[alias_form(model)] do
      {pin, pout} -> ((pin || pout || 0.0) + (pout || pin || 0.0)) / 2
      _ -> nil
    end
  end

  def rate(_), do: nil

  @doc "Snapshot of the registry — for diagnostics."
  def all, do: :persistent_term.get(@pt, %{})

  # ── self-warming GenServer (boot + periodic CF price refresh) ────────────────────────────────────

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    # Warm shortly after boot (lets the secret broker come up first), then on a long interval. So the
    # registry is populated BEFORE real traffic — no cold window where a CF call meters $0.
    Process.send_after(self(), :refresh, 5_000)
    {:ok, nil}
  end

  @impl true
  def handle_info(:refresh, state) do
    safe_refresh()
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, state}
  end

  @doc "Force a CF price refresh now (also runs on boot + every 12h). Returns {:ok, count} | {:error, _}."
  def refresh_cf do
    with account when is_binary(account) <- cf_account(),
         token when is_binary(token) and token != "" <- Nexus.Secrets.get("CF_AIG_TOKEN") do
      priced =
        fetch_cf_models(account, token)
        |> Enum.flat_map(fn m ->
          {pin, pout} = cf_price(m)
          id = m["name"]
          if is_binary(id) and (pin || pout), do: [%{id: id, price_in: pin, price_out: pout}], else: []
        end)

      put_all(priced)
      {:ok, length(priced)}
    else
      _ -> {:error, :cf_unconfigured}
    end
  end

  defp safe_refresh do
    refresh_cf()
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  # The CF account id is embedded in the gateway URL (`…/v1/{account}/{gateway}/…`) — no separate secret.
  defp cf_account do
    case Nexus.Secrets.get("CF_AIG_URL") do
      url when is_binary(url) -> (Regex.run(~r{/v1/([^/]+)/}, url) || []) |> Enum.at(1)
      _ -> nil
    end
  end

  # Paginate the official models API (Text Generation) until a short page. CF's response carries pricing.
  defp fetch_cf_models(account, token, page \\ 1, acc \\ [])

  defp fetch_cf_models(account, token, page, acc) when page <= 12 do
    url =
      "https://api.cloudflare.com/client/v4/accounts/#{account}/ai/models/search" <>
        "?per_page=50&page=#{page}&task=Text%20Generation"

    case cf_get(url, token) do
      {:ok, %{"result" => list}} when is_list(list) and list != [] ->
        if length(list) < 50, do: acc ++ list, else: fetch_cf_models(account, token, page + 1, acc ++ list)

      _ ->
        acc
    end
  end

  defp fetch_cf_models(_account, _token, _page, acc), do: acc

  defp cf_get(url, token) do
    :ssl.start()
    :inets.start()
    headers = [{~c"authorization", String.to_charlist("Bearer " <> token)}]

    case :httpc.request(:get, {String.to_charlist(url), headers}, [timeout: 20_000], body_format: :binary) do
      {:ok, {{_, 200, _}, _, body}} -> Jason.decode(body)
      _ -> :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  # The pricing property is a list of `%{"price" => n, "unit" => "per M input/output tokens"}` — split it.
  defp cf_price(m) do
    list =
      (m["properties"] || [])
      |> Enum.find_value([], fn p ->
        v = p["value"]
        if is_list(v) and Enum.any?(v, fn x -> is_map(x) and Map.has_key?(x, "price") end), do: v, else: false
      end)

    {price_for(list, "input"), price_for(list, "output")}
  end

  defp price_for(list, dir) do
    Enum.find_value(list, fn x ->
      if is_map(x) and is_number(x["price"]) and String.contains?(String.downcase(to_string(x["unit"] || "")), dir),
        do: x["price"] * 1.0,
        else: nil
    end)
  end

  # CF models route under both `workers-ai/@cf/…` (gateway compat) and the bare `@cf/…`; match either.
  defp alias_form("workers-ai/" <> rest), do: rest
  defp alias_form(m), do: "workers-ai/" <> m

  defp num(n) when is_number(n), do: n * 1.0
  defp num(_), do: nil
end
