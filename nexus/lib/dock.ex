defmodule Nexus.Dock do
  @moduledoc """
  The runtime capability **membrane** — the live host implementations a sandboxed component runs
  against (SSRF-brokered `fetch`, `llm_complete`, the kv store, the wasmex import map). The capability
  *catalog* (what exists, the WIT each projects, the grant vocabulary) lives in `Nexus.Capabilities`
  so the `.work` toolchain (`Nexus.Wit`) and this seam read one source of truth; the catalog queries
  below delegate there.
  """

  alias Nexus.Capabilities

  @doc """
  Host functions a unit can call by name → `{wit_signature, impl}`. The signature is the WIT the
  unit's import is typed with; the impl is what runs on the host.
  """
  def host_fns, do: host_fns(Nexus.Store.default_tenant())

  @doc """
  Host functions **bound to a tenant**. Every stateful cap (`store`/`load`/`cache_*`) closes over
  `tenant` at instantiation, so the guest names only a key — the partition is host-supplied and a
  guest can NEVER address another tenant's data (the tenant is captured here, never read from guest
  arguments). `tenant` is the caller's request tenant (`Nexus.Auth`/`Nexus.Sandbox.start`).
  """
  def host_fns(tenant) do
    %{
      "now" => {"func() -> s64", fn -> System.os_time(:second) end},
      # `emit`, not `log` — `log` collides with libm's math `log`.
      "emit" => {"func(msg: string)", fn msg -> require(Logger) && Logger.info(["[unit] ", msg]); nil end},
      # tenant-partitioned in-memory kv (proves the canonical-ABI return path). The key is
      # {:nexus_kv, tenant, k} — tenant A and tenant B sharing key "x" hold DISTINCT cells.
      "store" => {"func(key: string, val: string)", fn k, v -> :persistent_term.put({:nexus_kv, tenant, k}, v); nil end},
      "load" => {"func(key: string) -> string", fn k -> :persistent_term.get({:nexus_kv, tenant, k}, "") end},
      # the real, tiered, tenant-scoped cache (Nexus.Cache) — the durable counterpart to store/load.
      # The guest names only a key; the host binds `tenant` so a guest can never read/poison another
      # tenant's cache.
      "cache_get" =>
        {"func(key: string) -> string",
         fn k -> with({:ok, v} <- Nexus.Cache.get(tenant, cache_ns(), k), do: v, else: (_ -> "")) end},
      "cache_put" =>
        {"func(key: string, val: string, ttl: u32)",
         fn k, v, ttl -> Nexus.Cache.put(tenant, cache_ns(), k, v, ttl: ttl); nil end},
      "cache_delete" =>
        {"func(key: string)", fn k -> Nexus.Cache.delete(tenant, cache_ns(), k); nil end},
      # net: a TLS-verified HTTP GET, SSRF-brokered (see fetch/1).
      "fetch" => {"func(url: string) -> string", &__MODULE__.fetch/1},
      # llm: a chat completion (OpenRouter). Returns "" if no key is configured.
      "complete" => {"func(prompt: string) -> string", &__MODULE__.llm_complete/1}
    }
  end

  # The cache namespace the guest's cache_* caps write under (tenant is the partition; namespace
  # groups the dock kv within a tenant).
  defp cache_ns, do: "dock"

  # ── capability grant gating ──────────────────────────────────────────────────────────────────
  # Host import name → the grant word(s) that unlock it. A name absent here is AMBIENT (always
  # wired: `now`/`emit` are pure time + log, harmless). A guest gets ONLY the imports its unit
  # granted; an ungranted import is omitted, so instantiation fails if the guest declares it.
  @cap_grants %{
    "store" => ["kv"],
    "load" => ["kv"],
    "cache_get" => ["kv"],
    "cache_put" => ["kv"],
    "cache_delete" => ["kv"],
    "fetch" => ["net", "browse"],
    "complete" => ["llm"]
  }

  @doc "The grant word(s) that unlock a host import, or `[]` if it's ambient (always available)."
  def grant_for(name), do: Map.get(@cap_grants, name, [])

  defp granted?(name, _caps) when not is_map_key(@cap_grants, name), do: true
  defp granted?(_name, :all), do: true
  defp granted?(name, caps), do: Enum.any?(@cap_grants[name], &(&1 in caps))

  @doc """
  SSRF-brokered HTTP GET for the `fetch` cap. ALWAYS blocks loopback/private/link-local hosts and
  non-http(s) schemes. If `NEXUS_NET_ALLOW` is set the URL's host must be on it. `""` on block/failure.
  """
  def fetch(url) do
    if net_allowed?(url) do
      t0 = System.monotonic_time(:millisecond)

      body =
        case Nexus.Compilers.Shared.http_get(url) do
          {:ok, body} -> body
          _ -> ""
        end

      # Record into the active network capture (a cheap no-op when none is open). This is THE seam
      # that makes a HAR possible — one chokepoint sees every fetch.
      Nexus.Browse.Capture.record(url, body, System.monotonic_time(:millisecond) - t0)
      body
    else
      Nexus.Browse.Capture.record(url, "", 0)
      ""
    end
  end

  @doc """
  The SSRF gate, exposed so any host-side fetch escalation (e.g. the curl-impersonate fallback in
  `Nexus.Compilers.Shared.http_get/1`) re-guards itself before egress — never an unguarded path.
  Delegates to the ONE guard (`Nexus.Net.Ssrf`, wb-y4md) — resolve-then-check-every-IP, shared with
  the keyed-search `get/2` path; the old literal-hostname check that let a public name resolving to an
  internal IP through is gone.
  """
  def net_allowed?(url), do: Nexus.Net.Ssrf.allowed?(url)

  @doc """
  SSRF-guarded HTTPS GET with custom request `headers` (e.g. an `X-Subscription-Token` for a keyed
  search API) → `{:ok, body}`. Verifies TLS via the OS trust store. Re-guards the host through the
  same SSRF gate as `fetch/1` before egress. For the keyed search providers (Brave/Exa/Tavily).
  """
  def get(url, headers \\ []) do
    if net_allowed?(url) do
      :inets.start()
      :ssl.start()

      ssl_opts = [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)],
        depth: 3
      ]

      hdrs = Enum.map(headers, fn {k, v} -> {String.to_charlist(to_string(k)), String.to_charlist(to_string(v))} end)
      req = {String.to_charlist(url), hdrs}
      http_opts = [ssl: ssl_opts, timeout: 30_000, connect_timeout: 15_000, autoredirect: true]

      case :httpc.request(:get, req, http_opts, body_format: :binary) do
        {:ok, {{_v, 200, _}, _h, body}} -> {:ok, body}
        {:ok, {{_v, code, _}, _h, _body}} -> {:error, {:http_status, code}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :blocked}
    end
  end

  @doc false
  @llm_model "openai/gpt-4o-mini"
  def llm_complete(prompt) do
    key = Nexus.Secrets.get("OPENROUTER_API_KEY")

    if key do
      :inets.start()
      :ssl.start()
      body = Jason.encode!(%{model: @llm_model, messages: [%{role: "user", content: prompt}]})

      ssl_opts = [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]

      req = {~c"https://openrouter.ai/api/v1/chat/completions", [{~c"authorization", ~c"Bearer #{key}"}], ~c"application/json", body}

      case :httpc.request(:post, req, [ssl: ssl_opts, timeout: 60_000], body_format: :binary) do
        {:ok, {{_, 200, _}, _h, resp}} ->
          case Jason.decode(resp) do
            {:ok, %{"choices" => [%{"message" => %{"content" => c}} | _]}} -> c || ""
            _ -> ""
          end

        _ ->
          ""
      end
    else
      ""
    end
  end

  @doc "Whether a host fn returns a string (→ the unit's component needs a cabi_realloc export)."
  def returns_string?(name), do: (host_fn_wit(name) || "") |> String.contains?("-> string")

  @doc "The WIT signature for a host fn the unit imports, or nil if it isn't a known cap."
  def host_fn_wit(name), do: with({sig, _impl} <- host_fns()[name], do: sig)

  @doc """
  Host implementations the Dock supplies to a sandboxed component, as the wasmex import map
  (`%{"name" => {:fn, impl}}`), **tenant-bound and grant-filtered**.

  `tenant` partitions every stateful cap. `caps` is the unit's granted capability words (from
  `Nexus.Capabilities.grants/1`); only ambient imports + imports whose grant is in `caps` are wired,
  so a guest cannot reach a capability it never granted. `caps: :all` wires the full surface (the
  default — used by trusted/in-tree callers and tests; the untrusted seam passes real grants).
  """
  def impls(tenant \\ Nexus.Store.default_tenant(), caps \\ :all) do
    host_fns(tenant)
    |> Enum.filter(fn {n, _} -> granted?(n, caps) end)
    |> Map.new(fn {n, {_sig, f}} -> {n, {:fn, f}} end)
  end

  # ── capability catalog — the source of truth is Nexus.Capabilities; delegate so existing
  #    Nexus.Dock.<catalog> callers (and the runtime seam) keep one vocabulary. ───────────────────
  defdelegate capabilities(), to: Capabilities
  defdelegate sandbox_capabilities(), to: Capabilities
  defdelegate runtime_capabilities(), to: Capabilities
  defdelegate cap_for_dock_fn(fn_name), to: Capabilities
  defdelegate capability?(cap), to: Capabilities
  defdelegate sandbox_capability?(cap), to: Capabilities
  defdelegate interface_name(cap), to: Capabilities
  defdelegate interface_wit(cap), to: Capabilities
  defdelegate import_name(cap), to: Capabilities
  defdelegate runtime_cap_for(grant), to: Capabilities
  defdelegate grant_import(grant), to: Capabilities
  defdelegate rust_ambient(), to: Capabilities
  defdelegate rust_abi(cap), to: Capabilities
  defdelegate rust_abi_names(), to: Capabilities
  defdelegate registry(), to: Capabilities
  defdelegate engine_world(), to: Capabilities
end
