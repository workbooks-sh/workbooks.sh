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
        component-cache="build/components"   # store location (path or s3://bucket/prefix)
        languages="rust zig c"         # toolchains this deployment enables/pre-warms
        cache-hot-max-mb="64"          # Nexus.Cache hot-tier ETS byte budget (LRU-bounded)
        cache-default-ttl="3600"       # Nexus.Cache cold-tier shelf-life, seconds
        cache-cold="cache"             # cold-tier backend: a local path (→ Local) OR s3://bucket/prefix (→ S3)
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

  # The deploy block lives in the deploy-root `index.work` (deploy-as-index-tree — see
  # docs/deploy-as-index-tree.md). `deployment.work` is a TRANSITIONAL fallback only, being retired.
  # First hit wins; no env knob points here (convention, not a bootstrap env var).
  @fallbacks ["deployment.work", "/app/deployment.work", "/data/deployment.work"]

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
  def subproc_concurrency, do: get(:subproc_concurrency)
  def render_concurrency, do: get(:render_concurrency)
  def compile_cache?, do: get(:compile_cache)
  def compile_cache_version, do: get(:compile_cache_version)
  def component_cache, do: get(:component_cache)
  def component_cache_endpoint, do: get(:component_cache_endpoint)
  def component_cache_region, do: get(:component_cache_region)
  def languages, do: get(:languages)
  def pm_debug?, do: get(:pm_debug)
  # Untrusted-guest sandbox limits (wb-9jqy). Neutral safe defaults; deployer dials via deploy block.
  def sandbox_memory_mb, do: get(:sandbox_memory_mb)
  def sandbox_epoch_secs, do: get(:sandbox_epoch_secs)
  def sandbox_table_elements, do: get(:sandbox_table_elements)
  def sandbox_max_instances, do: get(:sandbox_max_instances)
  def sandbox_proc_memory_mb, do: get(:sandbox_proc_memory_mb)
  def sandbox_compile_memory_mb, do: get(:sandbox_compile_memory_mb)
  # Washy in-process interpreter per-run bounds (deploy-tunable; neutral defaults).
  def washy_fuel, do: get(:washy_fuel)
  def washy_timeout_ms, do: get(:washy_timeout_ms)
  def washy_max_output, do: get(:washy_max_output_mb) * 1024 * 1024
  def washy_max_depth, do: get(:washy_max_depth)
  def washy_max_pages, do: get(:washy_max_pages)
  def washy_max_concurrent, do: get(:washy_max_concurrent)
  @doc "Run guests through the wasm→BEAM tiered transpiler (native-compile hot functions, interpret the rest). Correct + cached; neutral mechanism a deployer can disable."
  def washy_transpile?, do: get(:washy_transpile)
  @doc "Washy per-run bounds as an opts keyword list (fuel/timeout_ms/max_output/max_depth/max_pages)."
  def washy_limits, do: [fuel: washy_fuel(), timeout_ms: washy_timeout_ms(), max_output: washy_max_output(), max_depth: washy_max_depth(), max_pages: washy_max_pages()]
  def net_allow, do: get(:net_allow)
  def llm_calls_per_min, do: get(:llm_calls_per_min)
  def fetch_calls_per_min, do: get(:fetch_calls_per_min)
  def untrusted_workspaces, do: get(:untrusted_workspaces)
  # Tenant-aware cache (Nexus.Cache): hot ETS byte budget + cold-tier shelf-life. The hot tier is
  # deliberately small (default 64MB) so on a 1GB host it never competes with agents for RAM.
  def cache_hot_max_mb, do: get(:cache_hot_max_mb)
  def cache_default_ttl, do: get(:cache_default_ttl)
  # Cold-tier backend spec — a local filesystem path (→ Nexus.Cache.Cold.Local) OR an `s3://` bucket
  # URI (→ Nexus.Cache.Cold.S3; `r2://` is a deprecated alias). Mirrors `component-cache`: the operator picks cloud-vs-local
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

  # ── deploy MODE (the keystone of local↔cloud parity) ──────────────────────────────────────────
  # The declared mode strings, and the adapter modules the runtime selects from them. Same on every
  # target → a workbook behaves identically local + cloud.
  def auth, do: get(:auth)
  def database, do: get(:database)
  def storage, do: get(:storage)
  def tenancy_mode, do: get(:tenancy_mode)
  def jj_substrate?, do: get(:jj_substrate)
  @doc "Route the agent shell through real bash+coreutils in wasm (Wasmer/WASIX) for non-host-builtin lines. Off until the WASIX packages are rebuilt clean (wb-d2bd)."
  def wasix_shell?, do: get(:wasix_shell)

  @doc "Authorship enforcement at the nexus commit boundary: :off | :soft (verify+record) | :hard (reject unsigned)."
  def authorship_policy do
    case get(:authorship_policy) do
      p when p in ["off", "soft", "hard"] -> String.to_atom(p)
      _ -> :soft
    end
  end

  @doc "The pinned/published ledger trust anchor did:key (fix wb-8hax), or nil if the deploy hasn't pinned one."
  def ledger_did, do: get(:ledger_did)

  def cpus, do: get(:cpus)
  def memory, do: get(:memory)

  @doc "The request-auth adapter the declared `auth` mode selects (default `Nexus.Auth.None` = trusted)."
  def auth_adapter do
    case auth() do
      "trusted" -> Nexus.Auth.None
      "bearer" -> Nexus.Auth.Bearer
      m when m in ~w(betterauth clerk oidc jwt auth0) -> Nexus.Auth.Jwt
      _ -> Nexus.Auth.None
    end
  end

  @doc """
  The store adapter the declared `database` mode selects. `sqlite` → `Nexus.Store.Sqlite` (the durable
  default, replicated by Litestream when storage secrets are present). `postgres` has no adapter yet —
  it returns `:postgres_unimplemented` so the caller can fail LOUD rather than silently use SQLite.
  """
  def store_adapter do
    case database() do
      "sqlite" -> Nexus.Store.Sqlite
      "postgres" -> :postgres_unimplemented
      _ -> Nexus.Store.Sqlite
    end
  end

  @doc """
  The PRIMARY JS/WASM runtime for the sandbox. `:tiny_lasers` (default) — pure-BEAM WASM, the emulation
  thesis, prioritized wherever it can run. `Nexus.JsEngine` automatically falls back to **wasmex**
  (wasmtime + StarlingMonkey) when TinyLasers can't handle a script — e.g. its node-based Porffor
  pipeline isn't present in the slim cloud runtime. `WB_JS_RUNTIME=wasmex` forces wasmtime outright.
  """
  def js_runtime do
    case System.get_env("WB_JS_RUNTIME") do
      "wasmex" -> :wasmex
      _ -> :tiny_lasers
    end
  end

  @doc """
  Emails permitted to sign up / log in, lowercased. Locks the control plane to our own account(s) in
  production via `WB_LOGIN_ALLOWLIST` (comma-separated). Empty/unset ⇒ open (dev + self-host default).
  """
  def login_allowlist do
    case System.get_env("WB_LOGIN_ALLOWLIST") do
      v when is_binary(v) and v != "" ->
        v
        |> String.split(",")
        |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
        |> Enum.reject(&(&1 == ""))

      _ ->
        []
    end
  end

  @doc """
  Whether the local micro-VM **Forge** (`Nexus.Forge` — the agent's vfkit compute-terminal failsafe for
  builds the WASM sandbox can't host, see `nexus/docs/micro-vms.md`) may run. **LOCAL-ONLY by design**:
  off unless `WB_FORGE=1`, AND hard-false whenever this looks like a deployed nexus (a tenant / Fly app
  is set) so a cloud machine can never open a nested micro-VM.
  """
  def forge_enabled? do
    System.get_env("WB_FORGE") == "1" and
      System.get_env("NEXUS_TENANT") in [nil, ""] and
      System.get_env("FLY_APP_NAME") in [nil, ""]
  end

  # Org capacity TIERS — a config-driven primitive. THE LINE: the runtime ships a NEUTRAL default
  # (one unbounded free tier, no imposed ceiling, domains allowed); an operator supplies their OWN
  # tiers + prices via this deploy config, never hardcoded in `lib/`. Each `tiers` line is
  # `id | Name | ram_mb storage_gb price_usd domains(yes|no)`, cheapest → biggest.
  def tiers, do: get(:tiers)

  # The OCI image the provisioner deploys for a tenant nexus. Defaults to the published open-standard
  # runtime image; an operator running their own build overrides it. (Operator config, not business.)
  def runtime_image, do: get(:runtime_image)
  @doc "Allowed image-ref prefixes (ArtifactTrust). [] ⇒ permissive (neutral default)."
  def image_registries, do: get(:image_registries)
  @doc "Pinned image digests, `%{repo => \"sha256:<hex>\"}` (ArtifactTrust). %{} ⇒ unpinned."
  def image_pins, do: get(:image_pins)

  # Hostnames an operator reserves (their own domain of record) — a tenant can't bind a custom domain
  # under these. Neutral default: NONE. We supply our own (`workbooks.sh`) via our deploy config.
  def reserved_hosts, do: get(:reserved_hosts)

  # Session cookie knobs (Nexus.Auth.Session). `session_secure?` defaults TRUE (httpS-only cookie);
  # an http-only dev nexus sets `session-secure="off"`. max-age in seconds (default 24h).
  def session_secure?, do: get(:session_secure)
  def session_max_age, do: get(:session_max_age)
  def session_cookie, do: get(:session_cookie)

  # The org's declared workspaces (curated folders, `deploy workspaces="folder | Name | emoji"`) and
  # the nexus's own display emoji. Neutral defaults: [] / nil — deployers declare their own.
  def workspaces, do: get(:workspaces)
  def nexus_emoji, do: get(:nexus_emoji)

  # The HOME surface — the subtree mounted at `/` (the nexus homepage). Its descendants rebase too
  # (`home="lander"` ⇒ surface `lander` serves at `/`, `lander/blog` at `/blog`). nil ⇒ no home surface;
  # `/` then shows the mounted-workbooks index. This is the deploy choice of "which surface is the front
  # door" — config, not a magic folder name.
  def home, do: get(:home)

  # Login providers (Nexus.Auth.Provider). Declared as `auth-provider-<name>-<key>="…"` deploy attrs,
  # e.g. `auth-provider-google-authorize-url`, `-token-url`, `-jwks-url`, `-client-id`, `-issuer`,
  # `-scope`, `-redirect-uri`, `-tenant-claim`. Secrets (client_secret) live in Nexus.Secrets, NEVER
  # here. `provider/1` → the whole map; `provider/3` → one key.
  def providers, do: get(:providers)
  def provider(name), do: Map.get(providers(), to_string(name), %{})
  def provider(name, key, default \\ nil), do: Map.get(provider(name), to_string(key), default)

  # Cloudflare-for-SaaS custom-hostname config. `cf_saas_zone` = the CF zone id that owns the fallback
  # origin; `cf_custom_hostname_origin` = the CNAME target customers point their domain at. Both nil ⇒
  # the feature is off and Nexus.ControlPlane.Domain stays on the Fly-cert path.
  def cf_saas_zone, do: get(:cf_saas_zone)
  def cf_custom_hostname_origin, do: get(:cf_custom_hostname_origin)

  # ── Polar billing (OUR cloud's config; another operator brings their own) ──────────────────────
  # The Polar server the runtime talks to: "sandbox" (default — isolated test env) | "production".
  # The access token + webhook secret are SECRETS (Nexus.Secrets), never config. `polar_product/1`
  # maps a subscription tier id → its Polar product UUID (`deploy polar-product-<tier>="uuid"`);
  # `polar_credit_product/0` is the one-time custom-amount product for inference credit top-ups
  # (`deploy polar-credit-product="uuid"`). All nil by default — billing stays off until configured.
  def polar_server, do: get(:polar_server)
  def polar_products, do: get(:polar_products)
  def polar_product(tier), do: Map.get(polar_products(), to_string(tier))
  def polar_credit_product, do: get(:polar_credit_product)

  # ── parse ─────────────────────────────────────────────────────────────────────────────────────
  defp parse(html) do
    %{
      compile_concurrency: int(attr(html, "compile-concurrency"), System.schedulers_online()),
      # Render slots: each post-AOT render holds ~47MB. Default sizes to host RAM (≈1 slot/100MB,
      # leaving ~300MB for the BEAM), capped to a sane band; `deploy render-concurrency` overrides.
      render_concurrency: int(attr(html, "render-concurrency"), default_render_concurrency()),
      compile_cache: bool(attr(html, "compile-cache"), true),
      compile_cache_version: attr(html, "compile-cache-version") || "wbc2",
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
      # ── deploy MODE: the same knobs `work deploy` scaffolds/validates, now read by the runtime so a
      # workbook runs in its DECLARED mode on EVERY target (local vfkit == cloud Fly) — no divergence.
      # `auth` selects the request-auth adapter; `database`/`storage`/`tenancy-mode` are the data
      # posture. Neutral defaults match today's behavior (trusted/single/sqlite/local-fs).
      auth: attr(html, "auth") || "trusted",
      database: attr(html, "database") || "sqlite",
      storage: attr(html, "storage") || "local-fs",
      tenancy_mode: attr(html, "tenancy-mode") || "single",
      # ── untrusted-guest sandbox limits (wb-9jqy). Neutral SAFE defaults so a deployer hosting
      # untrusted multi-tenant WASM is bounded out of the box; a deployer running only its own
      # (trusted) code can raise them. Per-guest linear-memory cap (MiB), per-call wall-clock CPU
      # deadline (seconds, via epoch interruption), and per-table element cap.
      sandbox_memory_mb: int(attr(html, "sandbox-memory-mb"), 256),
      sandbox_epoch_secs: int(attr(html, "sandbox-epoch-secs"), 5),
      sandbox_table_elements: int(attr(html, "sandbox-table-elements"), 100_000),
      # Cap on instances/memories/tables PER STORE — bounds instance fan-out without breaking
      # legitimate multi-instance hosts (the eval-host runs guest + host in one store). The dominant
      # OOM lever is the per-memory `sandbox-memory-mb` cap; per-tenant concurrency (wb-whvy) is the
      # complementary fan-out bound across stores.
      sandbox_max_instances: int(attr(html, "sandbox-max-instances"), 32),
      # Command-lane (external `wasmtime run`) per-guest linear-memory cap (MiB) — toolkits/js/python
      # command modules. Generous default (covers an interpreter working set) but bounded so a runaway
      # grow traps instead of exhausting host RAM.
      sandbox_proc_memory_mb: int(attr(html, "sandbox-proc-memory-mb"), 512),
      # Compile/proc-macro subprocess linear-memory cap (MiB) — the clang/mrustc/proc-macro lane needs
      # a much larger working set than a command module (libstd builds reach ~GBs), so it gets its own
      # generous default. Still bounded so a memory.grow loop in a build script can't exhaust host RAM.
      sandbox_compile_memory_mb: int(attr(html, "sandbox-compile-memory-mb"), 3072),
      # Washy (in-process wasm interpreter) per-run bounds — the dense BEAM lane that runs the agent
      # shell + host_exec'd programs. Neutral safe defaults; a deployer dials them via the deploy block.
      # fuel = instruction budget (runaway-work bound); the rest are wall-clock / output / recursion /
      # linear-memory ceilings. All enforced as catchable traps, never a host fault.
      washy_fuel: int(attr(html, "washy-fuel"), 2_000_000_000),
      washy_timeout_ms: int(attr(html, "washy-timeout-ms"), 30_000),
      washy_max_output_mb: int(attr(html, "washy-max-output-mb"), 16),
      washy_max_depth: int(attr(html, "washy-max-depth"), 10_000),
      washy_max_pages: int(attr(html, "washy-max-pages"), 4096),
      # Soft concurrency cap on in-flight Washy runs — backpressure under a flood. Generous default
      # (runs are individually bounded + cells are tiny); a new run waits for a slot up to its timeout.
      washy_max_concurrent: int(attr(html, "washy-max-concurrent"), 512),
      # Tiered wasm→BEAM transpilation: native-compile the hot functions, interpret the rest, all over
      # shared state. Bit-identical to pure interpretation (oracle-gated) + cached per module. OFF by
      # default until the op surface is validated for large interpreters (quickjs/CPython) and confirmed
      # net-positive per workload — it wins on COMPUTE-bound guests (tight numeric loops: 14–34×) but is
      # neutral-to-negative on I/O-bound ones (a shell whose work is nested interpreted coreutils). A
      # deployer (or a validated compute lane) opts in with washy-transpile="on".
      washy_transpile: bool(attr(html, "washy-transpile"), false),
      # Concurrent heavy wasmtime subprocesses spawned from inside a compile (proc-macro servers, build
      # scripts) — bounds their fan-out so a malicious crate's N build scripts can't exhaust host RAM.
      subproc_concurrency: int(attr(html, "subproc-concurrency"), System.schedulers_online()),
      # Host-side guest egress allowlist (the `fetch`/`get` SSRF guard, Nexus.Net.Ssrf). A deploy
      # attr, NOT an env var (THE LINE / no env config). Empty = allow any PUBLIC host (internal is
      # always denied); listed = only those hosts.
      net_allow: words(attr(html, "net-allow"), []),
      # Per-tenant Dock cost/egress caps (wb-9g6s) — calls per minute per tenant for the `complete`
      # (LLM, the org API-spend drain) and `fetch` (egress) caps. Generous neutral defaults; 0 = no cap.
      llm_calls_per_min: int(attr(html, "llm-calls-per-min"), 60),
      fetch_calls_per_min: int(attr(html, "fetch-calls-per-min"), 120),
      # Trust tier (wb-rh95): subtree prefixes whose workspaces are UNTRUSTED — their authors may only
      # write wasm kinds (client/sandbox); native-BEAM kinds (server/worker/def/hook/test/auth) are
      # rejected at weave/load, since native Elixir can't be sandboxed in-process (the machine is the
      # trust wall). Neutral default [] = every workspace trusted (today's behavior; the deployer's own
      # code). A deployer hosting untrusted tenants lists their subtrees here.
      untrusted_workspaces: words(attr(html, "untrusted-workspaces"), []),
      # jj-as-substrate: route internal commits through Jujutsu (op-log + `jj undo`) over the workspace
      # git repo. No-op-safe (off ⇒ pure git; jj absent ⇒ pure git). Default off until proven on a deploy.
      jj_substrate: bool(attr(html, "jj-substrate"), false),
      # WASIX real-bash agent shell (epic wb-d2bd): route the agent's command line through real bash +
      # coreutils in wasm (Wasmer) instead of the Elixir shell. Default off until the WASIX packages are
      # rebuilt clean (the prebuilts lose output on nested $()-pipes + lack grep/sed/awk).
      wasix_shell: bool(attr(html, "wasix-shell"), false),
      # Authorship enforcement at the nexus commit boundary (epic wb-kodp) — the SINGLE chokepoint every
      # contribution crosses. "off" = no checks; "soft" = verify a device-key signature + record the
      # verified flag, never reject (the safe, non-breaking default); "hard" = reject any commit not
      # signed by a registered device key. Generic mechanism — any deployer picks their posture.
      authorship_policy: attr(html, "authorship-policy") || "soft",
      # The PINNED/published runtime trust anchor (epic wb-kodp, fix wb-8hax): the did:key whose
      # signatures count as authoritative metering. Verification anchors to THIS, never the live running
      # key (which an attacker-run nexus could mint + self-trust). Neutral default nil ⇒ a deploy that
      # hasn't pinned an anchor reads all metering as UNVERIFIED (fail closed). NO-JSON: a .work deploy
      # attr, not an env read.
      ledger_did: attr(html, "ledger-did"),
      # Machine shape for a LOCAL deploy — defaults match the cloud tier (1cpu/1024MB) so local doesn't
      # mask OOM/concurrency a cloud machine would hit. Overridable from the block for tier-faithful tests.
      cpus: int(attr(html, "cpus"), 1),
      memory: int(attr(html, "memory"), 1024),
      # Capacity tiers (operator-supplied; neutral single-tier default — see `tiers/0`).
      tiers: parse_tiers(attr(html, "tiers")),
      runtime_image: attr(html, "runtime-image") || "ghcr.io/workbooks-sh/runtime:latest",
      # ArtifactTrust policy (red-team wb-skhj/wb-b2ow): a generic, config-driven image-supply-chain
      # primitive — the runtime ships NEUTRAL defaults (no restriction), operators (incl. our DeployKit)
      # declare their own. `image-registries`: space-separated allowed ref prefixes; a deploy/WB_IMAGE ref
      # outside the list is refused. `image-pins`: space-separated `repo=sha256:<hex>` pins; a ref for a
      # pinned repo is rewritten to its digest. Empty ⇒ permissive (back-compat). See Nexus.ArtifactTrust.
      image_registries: words(attr(html, "image-registries"), []),
      image_pins: parse_pins(attr(html, "image-pins")),
      reserved_hosts: words(attr(html, "reserved-hosts"), []),
      session_secure: bool(attr(html, "session-secure"), true),
      session_max_age: int(attr(html, "session-max-age"), 86_400),
      session_cookie: attr(html, "session-cookie") || "wb_session",
      # The org's WORKSPACES — curated folders of work, declared canonically here (the deploy-kit
      # config), NOT auto-derived from every mount. Each line: `folder | Name | emoji`. Runtime ships
      # NONE; a deployer brings their own. Plus the nexus's own display emoji.
      nexus_emoji: attr(html, "nexus-emoji"),
      home: attr(html, "home"),
      workspaces: parse_workspaces(attr(html, "workspaces")),
      providers: parse_providers(html),
      # Cloudflare-for-SaaS custom hostnames (the cheap, scale path for customer domains — TLS terminated
      # at CF's edge, one CNAME per customer → our fallback origin → the tenant's Fly app). Both keys are
      # neutral/nil by default: with no SaaS zone configured the runtime stays on the per-app Fly-cert
      # path (Nexus.ControlPlane.Domain). The CF API TOKEN is a SECRET (Nexus.Secrets), never config.
      cf_saas_zone: attr(html, "cf-saas-zone"),
      cf_custom_hostname_origin: attr(html, "cf-custom-hostname-origin"),
      # Polar billing: server selection + product UUIDs (our cloud's config — see `polar_server/0`).
      polar_server: attr(html, "polar-server") || "sandbox",
      polar_products: parse_polar_products(html),
      polar_credit_product: attr(html, "polar-credit-product")
    }
  end

  # Scan the deploy block for `polar-product-<tier>="uuid"` → %{"<tier>" => "uuid"}. Neutral default: {}.
  defp parse_polar_products(html) do
    block =
      with src when is_binary(src) <- html,
           [_, b] <- Regex.run(~r/deploy\s+do\b(.*?)\n\s*end\b/s, src) do
        b
      else
        _ -> ""
      end

    Regex.scan(~r/polar-product-([a-z0-9]+)="([^"]*)"/i, block)
    |> Enum.reduce(%{}, fn [_, tier, uuid], acc -> Map.put(acc, String.downcase(tier), String.trim(uuid)) end)
  end

  defp parse_workspaces(nil), do: []

  defp parse_workspaces(src) do
    src
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case line |> String.trim() |> String.split("|") do
        [folder, name, emoji] -> [%{id: String.trim(folder), name: String.trim(name), icon: nilify(emoji)}]
        [folder, name] -> [%{id: String.trim(folder), name: String.trim(name), icon: nil}]
        _ -> []
      end
    end)
  end

  defp nilify(s), do: (t = String.trim(s)) == "" && nil || t

  # Scan the deploy block for `auth-provider-<name>-<key>="value"` → %{name => %{key => value}}.
  defp parse_providers(html) do
    block =
      with src when is_binary(src) <- html,
           [_, b] <- Regex.run(~r/deploy\s+do\b(.*?)\n\s*end\b/s, src) do
        b
      else
        _ -> ""
      end

    Regex.scan(~r/auth-provider-([a-z0-9]+)-([a-z0-9-]+)="([^"]*)"/i, block)
    |> Enum.reduce(%{}, fn [_, name, key, val], acc ->
      Map.update(acc, String.downcase(name), %{key => String.trim(val)}, &Map.put(&1, key, String.trim(val)))
    end)
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
  defdelegate data_dir, to: Nexus.Paths

  # Compiled wasm artifacts — EPHEMERAL by design (rebuilt by recompiling), so off the durable volume.
  defp default_cache_dir, do: Nexus.Paths.component_cache_dir()

  # Cold-tier default: on the persistent volume (`Nexus.Paths.cold_dir/0`) → durable across machine
  # churn. (Previously `<data_dir>/cache`, which was OUTSIDE the volume mount = silently ephemeral.)
  defp default_cold_dir, do: Nexus.Paths.cold_dir()

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

  # "repo=sha256:abc repo2=sha256:def" → %{"repo" => "sha256:abc", ...}. Neutral default %{}.
  defp parse_pins(nil), do: %{}

  defp parse_pins(s) when is_binary(s) do
    s
    |> String.split(~r/\s+/, trim: true)
    |> Enum.flat_map(fn pair ->
      case String.split(pair, "=", parts: 2) do
        [repo, digest] when repo != "" and digest != "" -> [{repo, digest}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  defp parse_pins(map) when is_map(map), do: map

  # The deploy root (the served tree) index.work first, then the transitional fallbacks.
  defp locate do
    root = System.get_env("WB_DATA") || File.cwd!()
    [Path.join(root, "index.work") | @fallbacks]
    |> Enum.find_value(fn p -> if File.regular?(p), do: File.read!(p) end)
  end
end
