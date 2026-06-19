defmodule Nexus.Config do
  @moduledoc """
  Runtime configuration — sourced from the deployment's `.work` config, a
  `deploy do … end` declaration (the source of truth), **not** environment
  variables. Composition-as-source: a knob is a setting you can read and diff in
  the `.work` file, never a hidden env sidecar (env config is JSON-by-another-name —
  same smell the NO-JSON rule forbids). HTML is only ever a build output, never a
  config surface.

  The ONLY things still read from the process env are genuine deploy-time **secrets +
  per-machine identity** (`OPENROUTER_API_KEY`, `NEXUS_DATA_TOKEN`, `NEXUS_TENANT`) —
  loaded INTO the nexus at deploy from an env file, never authored config. Everything
  tunable lives here.

  Loaded once into `:persistent_term` (lazily on first read, or eagerly via `boot/0`
  at app start). `reload/1` (the `.work` source string) and `put/2` are test seams.

      deploy do
        compile-concurrency="8"        # bound on concurrent wasm compiles (default: cores)
        compile-cache="on"             # content-addressed result cache (default: on)
        compile-cache-version="wbc1"   # bump to invalidate the whole store
        component-cache="build/components"   # store location (path or r2://bucket/prefix)
        languages="rust zig c"         # toolchains this deployment enables/pre-warms
        cache-hot-max-mb="64"          # Nexus.Cache hot-tier ETS byte budget (LRU-bounded)
        cache-default-ttl="3600"       # Nexus.Cache cold-tier shelf-life, seconds
        cache-cold="cache"             # cold-tier backend: a local path (→ Local) OR r2://bucket/prefix (→ R2)
        search="metasearch"            # :search provider: metasearch (keyless, local/dev) | brave (keyed, cloud)
        search-engines="ddg mojeek startpage"  # which keyless engines metasearch fans out to
        pm-debug="off"
        # Capacity tiers — operator-supplied; the runtime ships ONE neutral free tier when unset.
        # `id | Name | ram_mb storage_gb price_usd domains(yes|no)`. (These are OUR cloud's tiers — an
        # example of the *our cloud* side of THE LINE; another operator declares their own.)
        tiers="
          starter | Starter | 1024 10 0 no
          team    | Team    | 4096 100 49 yes
          scale   | Scale   | 16384 1000 199 yes
        "
        runtime-image="ghcr.io/workbooks-sh/runtime:latest"   # image the provisioner deploys per tenant
        reserved-hosts="workbooks.sh"   # operator's domain(s) of record — tenants can't bind under them
      end
  """
  @key {__MODULE__, :cfg}

  # Conventional locations the deployed/dev nexus looks for its config, first hit wins. No env knob
  # points here — it's convention, so there's no bootstrap env var to "configure the config".
  @sources ["deployment.work", "/app/deployment.work", "/data/deployment.work"]

  @doc "Eagerly load + cache the config (call once at app start, before the Gate reads its limit)."
  def boot, do: load(locate())

  @doc "Parse `html` (or nil → all defaults) into the cached config map. Returns the map."
  def load(html) do
    cfg = parse(html)
    :persistent_term.put(@key, cfg)
    cfg
  end

  @doc "Re-read from a `.work` source string (tests)."
  def reload(src), do: load(src)

  @doc "Override one key in the cached config (tests)."
  def put(key, val) do
    cfg = Map.put(current(), key, val)
    :persistent_term.put(@key, cfg)
    val
  end

  defp current, do: :persistent_term.get(@key, nil) || boot()
  defp get(key), do: Map.fetch!(current(), key)

  # ── typed getters (the public surface the runtime calls — never System.get_env) ───────────────
  def compile_concurrency, do: get(:compile_concurrency)
  def render_concurrency, do: get(:render_concurrency)
  def compile_cache?, do: get(:compile_cache)
  def compile_cache_version, do: get(:compile_cache_version)
  def component_cache, do: get(:component_cache)
  def component_cache_endpoint, do: get(:component_cache_endpoint)
  def component_cache_region, do: get(:component_cache_region)
  def languages, do: get(:languages)
  def pm_debug?, do: get(:pm_debug)
  # Tenant-aware cache (Nexus.Cache): hot ETS byte budget + cold-tier shelf-life. The hot tier is
  # deliberately small (default 64MB) so on a 1GB host it never competes with agents for RAM.
  def cache_hot_max_mb, do: get(:cache_hot_max_mb)
  def cache_default_ttl, do: get(:cache_default_ttl)
  # Cold-tier backend spec — a local filesystem path (→ Nexus.Cache.Cold.Local) OR an `r2://`/`s3://`
  # bucket URI (→ Nexus.Cache.Cold.R2). Mirrors `component-cache`: the operator picks cloud-vs-local
  # ONCE in deploy, and the same tier logic runs either way. Default: "cache" under data_dir.
  def cache_cold, do: get(:cache_cold)
  # Web-search provider: "metasearch" (keyless default) | "brave" | "exa" | "tavily" | "searxng".
  def search, do: get(:search)
  # Which keyless engines Metasearch fans out to (names: ddg mojeek startpage bing).
  def search_engines, do: get(:search_engines)
  # The base URL for the "searxng" provider only (an operator's self-hosted instance).
  def search_endpoint, do: get(:search_endpoint)
  # Embedding backend for the semantic reranker: "hashed" (keyless default) | model-swap names.
  def embed, do: get(:embed)

  # Org capacity TIERS — a config-driven primitive. THE LINE: the runtime ships a NEUTRAL default
  # (one unbounded free tier, no imposed ceiling, domains allowed); an operator supplies their OWN
  # tiers + prices via this deploy config, never hardcoded in `lib/`. Each `tiers` line is
  # `id | Name | ram_mb storage_gb price_usd domains(yes|no)`, cheapest → biggest.
  def tiers, do: get(:tiers)

  # The OCI image the provisioner deploys for a tenant nexus. Defaults to the published open-standard
  # runtime image; an operator running their own build overrides it. (Operator config, not business.)
  def runtime_image, do: get(:runtime_image)

  # Hostnames an operator reserves (their own domain of record) — a tenant can't bind a custom domain
  # under these. Neutral default: NONE. We supply our own (`workbooks.sh`) via our deploy config.
  def reserved_hosts, do: get(:reserved_hosts)

  # Session cookie knobs (Nexus.Auth.Session). `session_secure?` defaults TRUE (httpS-only cookie);
  # an http-only dev nexus sets `session-secure="off"`. max-age in seconds (default 24h).
  def session_secure?, do: get(:session_secure)
  def session_max_age, do: get(:session_max_age)
  def session_cookie, do: get(:session_cookie)

  # ── parse ─────────────────────────────────────────────────────────────────────────────────────
  defp parse(html) do
    %{
      compile_concurrency: int(attr(html, "compile-concurrency"), System.schedulers_online()),
      # Render slots: each post-AOT render holds ~47MB. Default sizes to host RAM (≈1 slot/100MB,
      # leaving ~300MB for the BEAM), capped to a sane band; `deploy render-concurrency` overrides.
      render_concurrency: int(attr(html, "render-concurrency"), default_render_concurrency()),
      compile_cache: bool(attr(html, "compile-cache"), true),
      compile_cache_version: attr(html, "compile-cache-version") || "wbc1",
      component_cache: attr(html, "component-cache") || default_cache_dir(),
      component_cache_endpoint: attr(html, "component-cache-endpoint"),
      component_cache_region: attr(html, "component-cache-region") || "auto",
      languages: words(attr(html, "languages"), :all),
      pm_debug: bool(attr(html, "pm-debug"), false),
      cache_hot_max_mb: int(attr(html, "cache-hot-max-mb"), 64),
      cache_default_ttl: int(attr(html, "cache-default-ttl"), 3600),
      cache_cold: attr(html, "cache-cold") || default_cold_dir(),
      # Web-search provider selection (the `:search` capability). Default = keyless metasearch
      # (pure-BEAM fan-out, great local/dev). Cloud should set `search="brave"` (keyed API, reliable
      # from datacenter IPs). The API key stays in env (BRAVE_API_KEY/…), like OPENROUTER_API_KEY.
      search: attr(html, "search") || "metasearch",
      search_engines: words(attr(html, "search-engines"), ~w(ddg mojeek startpage)),
      search_endpoint: attr(html, "search-endpoint"),
      # Embedding backend for the local semantic reranker. Default "hashed" (deterministic, keyless,
      # zero-dep); swap to a real GGUF/Bumblebee model name at Nexus.Embed's model-swap point.
      embed: attr(html, "embed") || "hashed",
      # Capacity tiers (operator-supplied; neutral single-tier default — see `tiers/0`).
      tiers: parse_tiers(attr(html, "tiers")),
      runtime_image: attr(html, "runtime-image") || "ghcr.io/workbooks-sh/runtime:latest",
      reserved_hosts: words(attr(html, "reserved-hosts"), []),
      session_secure: bool(attr(html, "session-secure"), true),
      session_max_age: int(attr(html, "session-max-age"), 86_400),
      session_cookie: attr(html, "session-cookie") || "wb_session"
    }
  end

  # The runtime's NEUTRAL default: one unbounded, free tier. No imposed ceiling (0 = unbounded in the
  # capacity dial), domains allowed. An open-standard nexus carries NO operator's business model.
  @default_tiers [%{id: "default", name: "Default", ram_mb: 0, storage_gb: 0, price: 0, domains?: true}]

  # `id | Name | ram_mb storage_gb price_usd domains(yes|no)` per line, cheapest → biggest.
  defp parse_tiers(nil), do: @default_tiers

  defp parse_tiers(src) do
    tiers =
      src
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn line ->
        case line |> String.trim() |> String.split("|") do
          [id, name, nums] ->
            case nums |> String.trim() |> String.split(~r/\s+/, trim: true) do
              [ram, storage, price, domains] ->
                [%{id: String.trim(id), name: String.trim(name), ram_mb: num(ram), storage_gb: num(storage),
                   price: num(price), domains?: String.downcase(String.trim(domains)) in ~w(yes true on 1)}]

              _ -> []
            end

          _ -> []
        end
      end)

    if tiers == [], do: @default_tiers, else: tiers
  end

  defp num(s) do
    case Integer.parse(String.trim(s)) do
      {n, _} -> n
      _ -> 0
    end
  end

  @doc """
  The persistent data root — the mounted volume (`WB_DATA`, e.g. `/data` in the libkrun VM / Fly
  machine), falling back to the cwd in dev. `WB_DATA` is the volume MOUNT PATH (deploy injection, set
  by the orchestrator), not a tunable knob — so reading it here is the legitimate kind of env, like
  `NEXUS_TENANT`. The local cache tier lives UNDER this so it survives restarts; the container rootfs
  would be wiped on every machine churn.
  """
  def data_dir, do: System.get_env("WB_DATA") || File.cwd!()

  defp default_cache_dir, do: Path.join([data_dir(), "build", "components"])

  # Cold-tier default: a `cache` dir on the persistent data volume → Nexus.Cache.Cold.Local. Durable
  # across machine restarts and the safe default when no R2 is configured (the local/libkrun route).
  defp default_cold_dir, do: Path.join(data_dir(), "cache")

  # ≈1 render slot per 100MB of host RAM (each post-AOT render ≈47MB; the /100 leaves headroom for
  # the BEAM + page working sets), within [2, 64]. Reads MemTotal on the Linux deploy target; on a
  # dev host without /proc/meminfo, falls back to the scheduler count.
  defp default_render_concurrency do
    mb =
      case File.read("/proc/meminfo") do
        {:ok, s} ->
          case Regex.run(~r/MemTotal:\s+(\d+)\s+kB/, s) do
            [_, kb] -> div(String.to_integer(kb), 1024)
            _ -> nil
          end

        _ ->
          nil
      end

    case mb do
      nil -> System.schedulers_online()
      mb -> mb |> Kernel.-(300) |> div(100) |> max(2) |> min(64)
    end
  end

  # Mirror the reactor's lightweight reader: read a `name="value"` setting from the
  # `deploy do … end` block of the .work config. No full parser needed for a flat list.
  defp attr(nil, _name), do: nil

  defp attr(src, name) do
    with [_, block] <- Regex.run(~r/deploy\s+do\b(.*?)\n\s*end\b/s, src),
         [_, v] <- Regex.run(~r/\b#{Regex.escape(name)}="([^"]*)"/s, block) do
      String.trim(v)
    else
      _ -> nil
    end
  end

  defp int(nil, default), do: default

  defp int(s, default) do
    case Integer.parse(s) do
      {n, _} when n > 0 -> n
      _ -> default
    end
  end

  defp bool(nil, default), do: default
  defp bool(s, _default) when is_binary(s), do: String.downcase(s) in ~w(on true yes 1)
  defp bool(b, _default) when is_boolean(b), do: b

  defp words(nil, default), do: default
  defp words(s, _default) when is_binary(s), do: String.split(s, ~r/\s+/, trim: true)
  defp words(list, _default) when is_list(list), do: list

  defp locate, do: Enum.find_value(@sources, fn p -> if File.regular?(p), do: File.read!(p) end)
end
