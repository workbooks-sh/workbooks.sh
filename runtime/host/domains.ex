defmodule Workbooks.Domains do
  @moduledoc """
  The public-plane domain registry (wb-1x1 P1, PUBLIC-WEB-PLAN.org). Maps a public
  HOST → the app it serves, and holds the per-host TLS cert used by `sni/1`.

  Design:
    * An ETS table (`:protected`, named) is the read path. `sni/1` runs inside the
      TLS acceptor on every handshake — it must be fast and must NOT call into a
      GenServer (head-of-line blocking). So reads hit ETS directly; only writes go
      through the GenServer (single writer).
    * Certs are materialized to files under build/cache/tls/ and `sni/1` returns
      `[certfile:, keyfile:]` — the SNI primitive that lets ONE Elixir node serve
      many domains with no second process (no Caddy). Cert issuance/renewal is P2
      (`Workbooks.Acme`); this module just stores+serves whatever cert it's given.

  Security: an unknown / unattached SNI host gets NO cert ([]), so its TLS handshake
  cannot complete — the registry is the admission gate for the public plane.
  """
  use GenServer

  @table :wb_domains
  @cache_subdir "cache/tls"

  # ── client ──────────────────────────────────────────────────────────────
  def start_link(_ \\ nil), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Attach a host to an app (status :pending until a cert is installed)."
  def attach(host, tenant, app), do: GenServer.call(__MODULE__, {:attach, norm(host), tenant, app})

  @doc "Install a PEM cert+key for a host (→ status :live, served by sni/1)."
  def put_cert(host, cert_pem, key_pem), do: GenServer.call(__MODULE__, {:put_cert, norm(host), cert_pem, key_pem})

  @doc "Forget a host."
  def delete(host), do: GenServer.call(__MODULE__, {:delete, norm(host)})

  @doc "All registered rows (host → map)."
  def all, do: ets() |> :ets.tab2list() |> Map.new()

  @doc """
  Resolve a HOST → app id for the content plane. Registered host wins; otherwise
  fall back to the leftmost DNS label (the P0 convention) so bare/subdomain demos
  keep working without an explicit registration.
  """
  def resolve(host) do
    h = norm(host)

    case lookup(h) do
      %{app: app} when is_binary(app) -> app
      _ -> first_label(h)
    end
  end

  @doc """
  TLS SNI callback (passed to ThousandIsland transport_options). Returns ssl options
  with the host's cert, or [] for an unknown host (handshake then fails — the gate).
  `servername` arrives as a charlist from :ssl.
  """
  def sni(servername) do
    case lookup(norm(to_string(servername))) do
      %{certfile: cf, keyfile: kf} when is_binary(cf) and is_binary(kf) ->
        [certfile: cf, keyfile: kf]

      _ ->
        []
    end
  end

  # ── server ──────────────────────────────────────────────────────────────
  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    File.mkdir_p!(cache_dir())
    {:ok, %{}}
  end

  @impl true
  def handle_call({:attach, host, tenant, app}, _from, s) do
    row = Map.merge(lookup(host) || %{}, %{host: host, tenant: tenant, app: app, status: :pending})
    :ets.insert(@table, {host, row})
    {:reply, {:ok, row}, s}
  end

  def handle_call({:put_cert, host, cert_pem, key_pem}, _from, s) do
    cf = Path.join(cache_dir(), "#{safe(host)}.crt")
    kf = Path.join(cache_dir(), "#{safe(host)}.key")
    File.write!(cf, cert_pem)
    File.write!(kf, key_pem)
    File.chmod(kf, 0o600)
    row = Map.merge(lookup(host) || %{host: host}, %{certfile: cf, keyfile: kf, status: :live})
    :ets.insert(@table, {host, row})
    {:reply, {:ok, row}, s}
  end

  def handle_call({:delete, host}, _from, s) do
    :ets.delete(@table, host)
    {:reply, :ok, s}
  end

  # ── helpers ──────────────────────────────────────────────────────────────
  defp ets, do: @table

  defp lookup(host) do
    case :ets.whereis(@table) do
      :undefined -> nil
      _ -> case :ets.lookup(@table, host), do: ([{^host, row}] -> row; _ -> nil)
    end
  end

  defp norm(host), do: host |> to_string() |> String.downcase() |> String.trim() |> String.split(":") |> hd()
  defp first_label(host), do: (case String.split(host, ".") do; [l | _] when l != "" -> l; _ -> nil end)
  defp safe(host), do: String.replace(host, ~r/[^a-z0-9._-]/i, "_")
  defp cache_dir, do: Path.join(File.cwd!(), "build/#{@cache_subdir}")
end
