# OQL Plugins — SaaS adapters as first-class plugins, no sidecar

*2026-06-02*

> CLEAN-ROOM RECONCILIATION (restored 2026-06-07 from workbooks-archive).
> This is the L4 SaaS-adapter design (the data-source/sync face of a federation
> toolkit — see linear/ and asana/). Carried forward as the plan of record for
> connectors. Reconciliations: WorkbooksRuntime.* module names map to Workbooks.*
> in runtime/host/*; the Backend behaviour it leans on is implemented
> (runtime/host/backend.ex + backend/{sqlite,postgres}.ex). The three-face
> federation pattern (base manifest + plugin/manifest.html + sync.md daemon) is
> summarized in TOOLKITS-V3.md §"Federation".

# Why this doc

  An earlier session committed to Steampipe (a Go sidecar exposing
  ~150 SaaS APIs as Postgres foreign tables) as the SaaS read-path
  adapter layer.  Re-evaluating in 2026-06-02:

  - Sidecar sprawl.  Steampipe = 1 service process + N plugin
    processes (each plugin is its own gRPC Go binary).  Stacked on
    the Tauri shell + the BEAM + libkrun microVM + workbook viewer,
    that's 7-8 OS processes per desktop install for ~5 SaaS
    connectors.  Operationally heavy.
  - Two query surfaces.  Steampipe ships SQL; OQL is our user-facing
    language.  We'd need a "SQL is a guest source-block language"
    framing for users, plus a OQL→SQL bridge.  The "OQL is the only
    surface" claim weakens.
  - NIF-ifying Steampipe is not feasible.  Steampipe is a server
    (embeds Postgres + plugin gRPC); NIFs are for function-shaped
    libraries.  Wrapping a server as a NIF would block BEAM
    schedulers and dangerously mix Go's preemptive GC with BEAM's
    preemptive scheduler.

  This doc replaces the Steampipe section in BYOD-PLAN.org with a
  cleaner architecture: SaaS sources are first-class **OQL plugins**,
  written in Elixir, running in the same BEAM as everything else.

# The architecture in one picture

> ┌─ OQL plugins (Notion, GitHub, Slack, Linear, Stripe, …)
> │     each = manifest.org + Elixir module
> │     each speaks SaaS API via Req
> │     each registers entities into the OQL vocabulary
> │
> OQL query routes to ──┼─ Plugin executor (entity-specific verbs:
> │                  (notion-page ...), (github-issue ...), …)
> │
> └─ Backend.{Sqlite|Postgres} (for indexed org content)
> via the Oql.Compiler/Index pipeline that already ships

  One BEAM.  Zero sidecars.  One query language.  Plugin auth +
  capabilities declared in the manifest, so DeployKit and the
  multi-tenant broker can wire credentials without imperative code.

# Reusing OQL's existing plugin system

  `substrates/oql/plugins/` already has a plugin mechanism.  Each
  plugin is an `.org` manifest with a `#+SLOT:` discriminator.  The
  shipping example is `substrates/oql/plugins/agent/manifest.org`
  with `#+SLOT: entity-binding` — declaring the schema for headlines
  tagged `:agent:`.

  We add a new slot:

```org
  #+TITLE: github
  #+VERSION: 1
  #+SLOT: data-source                 # NEW SLOT
  #+ENTITIES: github-repo github-issue github-pr github-user
  #+AUTH: pat                         # pat | oauth2 | service_account
  #+ENV_KEYS: GITHUB_TOKEN            # secrets DeployKit + wb env must inject
  #+CAPABILITIES: read write          # what the plugin actually supports
  #+SCOPE: tenant                     # tenant | workspace | global
  #+IMPL: WorkbooksRuntime.Plugin.Github
  #+DESCRIPTION: Query and mutate GitHub repos, issues, PRs, users.

  * Entities                                                  :entities:
  ** github-repo
     :PROPERTIES:
     :HEADLINE: GitHub Repo
     :OQL_PROPS: full_name owner name description stars forks language
     :END:

  ** github-issue
     :PROPERTIES:
     :HEADLINE: GitHub Issue
     :OQL_PROPS: number title state body author labels assignees created_at
     :END:

     ...
```

  The Elixir side: each plugin is a module implementing the
  `WorkbooksRuntime.Plugin` behaviour.

# The Plugin behaviour

```elixir
  defmodule WorkbooksRuntime.Plugin do
    @callback id() :: atom()
    @callback manifest_path() :: Path.t()
    @callback entities() :: [atom()]

    @callback init(opts :: keyword()) ::
                {:ok, state :: term()} | {:error, term()}

    # Read path — translate an OQL AST whose head verb is one of the
    # plugin's entities into a list of result maps (same shape the
    # SQL executor returns: id, document_path, level, title, ...).
    @callback query(state(), ast :: tuple(), opts :: keyword()) ::
                {:ok, [map()]} | {:error, term()}

    # Write path — apply a mutation. Mutations are structured tuples
    # the plugin defines (e.g. {:create_issue, repo, attrs}).
    @callback mutate(state(), mutation :: tuple()) ::
                {:ok, map()} | {:error, term()}

    @callback close(state()) :: :ok

    @optional_callbacks mutate: 2  # read-only plugins skip this
  end
```

# The auth shim

  `WorkbooksRuntime.Plugin.Auth.fetch(plugin_id, env_key, scope)` is
  the single place every plugin reads credentials from.  Three
  concrete sources, selected by deployment context:

| Context | Source |
| --- | --- |
| Local dev | process env, then `wb env` keychain |
| DeployKit tenant | tenant's bound secret store |
| Cloud cell | broker-issued per-tenant token |

  Plugins do NOT touch any of these directly.  They call `Auth.fetch`
  and trust the runtime to route.  This means a plugin written for
  local dev runs unchanged in a multi-tenant cloud deployment.

# Plugin registry + dispatch

  `WorkbooksRuntime.Plugin.Registry` scans plugin manifests on boot
  and builds an entity → plugin-module map:

      :github-repo  → WorkbooksRuntime.Plugin.Github
      :github-issue → WorkbooksRuntime.Plugin.Github
      :notion-page  → WorkbooksRuntime.Plugin.Notion
      :slack-message → WorkbooksRuntime.Plugin.Slack
      ...

  `Oql.Query.run` gains a new dispatch arm:

```elixir
  case head_verb(ast) do
    v when v in @oql_native_verbs ->
      # tags, todo, property, ... — native OQL evaluator path
      existing_dispatch(ast, opts)

    v ->
      case Plugin.Registry.lookup_by_entity(v) do
        {:ok, mod} -> mod.query(state, ast, opts)
        :error     -> {:error, {:unknown_verb, v}}
      end
  end
```

  Plugin queries are routed by the first verb in the AST — there's no
  ambiguity since plugin entity names (`github-issue`, `notion-page`)
  are kebab-case + namespaced and can't collide with native OQL verbs
  (`tags`, `todo`, `property`, etc.).

# DeployKit integration

  When a developer runs `wb deploy` on their workbooks app:

  1. DeployKit walks installed plugins (=runtime/engine/priv/plugins/
     <id>/manifest.org=).
  2. Aggregates the union of `#+ENV_KEYS:` across all plugins.
  3. Generates a deploy-time prompt: "Your tenants will need to
     provide: GITHUB_TOKEN, NOTION_TOKEN, SLACK_BOT_TOKEN."
  4. The broker stores per-tenant secrets and routes them at runtime
     via `Plugin.Auth.fetch`.

  Multi-tenant developer experience: a dev never writes auth-wiring
  code.  They install a plugin → DeployKit knows it needs $TOKEN →
  the broker issues per-tenant credentials → the plugin reads them
  transparently.

# Read vs Write

  **Read** is the v1 contract — every plugin implements `query/3`.

  **Write** (mutations) is the v2 add-on — plugins that support it
  implement `mutate/2`.  Each plugin defines its own mutation
  vocabulary:

  - GitHub: `{:create_issue, repo, attrs}`, ={:add_comment, issue,
    body}=, `{:close_issue, issue}`
  - Notion: `{:create_page, parent, props}`, ={:append_block, page,
    block}=, `{:update_props, page, props}`
  - Slack: `{:send_message, channel, body}`, `{:react, msg, emoji}`

  Mutations route through Workgate for permit (a destructive write
  to a customer's Notion needs the user's permission to proceed),
  then through `Plugin.mutate/2` against the plugin's auth-bound state.

  Agents reach mutations via a small `plugin` toolkit (not
  agent-callable as direct tools per CLAUDE.md rule 13; via the
  `bash` → `wb plugin <id> <verb> <args>` CLI path).

# What we DON'T do

  - No Steampipe sidecar. No Go binaries. No gRPC plugin processes.
    No localhost Postgres for SaaS data. Backend.Postgres is
    motivated by indexed-content storage in cloud cells + user-owned
    PG, NOT by Steampipe.

  - No "150 plugins free" claim. We hand-roll each plugin. The
    benefit decays anyway — most users care about 5-10 SaaS, not 150.
    The long tail is on whoever writes that plugin (us or community).

  - No SQL surface for SaaS. Users never write SQL against SaaS
    sources. They write OQL: `(notion-page (property "Status" "Done"))`.

  - No `wb` "plugin install" verb that downloads binaries.  Plugins
    are Elixir modules + org manifests shipped with the engine (or
    via Hex packages for community plugins).  No runtime fetch.

# Implementation order

  1. **Plugin behaviour** (`WorkbooksRuntime.Plugin`). ~30 LOC.
  2. **Manifest parser** — extends `Oql.Extract`-style parsing for
     `#+SLOT: data-source` manifests. ~100 LOC.
  3. **Plugin registry** (`WorkbooksRuntime.Plugin.Registry`) — scans
     `priv/plugins/` + dynamically-registered plugins; entity →
     module lookup. ~80 LOC.
  4. **Auth shim** (`WorkbooksRuntime.Plugin.Auth`) — three-context
     fetch (env / wb env keychain / broker). ~60 LOC.
  5. **Oql.Query dispatch update** — recognize plugin entity verbs and
     route to `Plugin.Registry.lookup_by_entity`. ~30 LOC.
  6. **First plugin: GitHub** — manifest + Elixir module + tests.
     Read-only initially; PAT auth via `GITHUB_TOKEN`. ~300 LOC.
  7. **Second + third plugins: Notion, Slack** — same pattern. ~300
     LOC each.
  8. **Write-back** on each — mutate/2 callback. ~150 LOC per plugin.
  9. **DeployKit integration** — plugin manifest discovery during
     deploy; aggregate ENV_KEYS; tenant onboarding form. Separate
     bd issue under DeployKit.
  10. **Workgate integration for mutations** — destructive writes
      require a permit. Separate bd issue under Workgate.

  Steps 1-5 are the foundation (~300 LOC). Each plugin (6, 7, 8)
  is ~300-450 LOC. DeployKit + Workgate hooks are cross-cutting
  follow-ups.

# What's NOT changing

  - OQL is the substrate. SaaS plugins exist inside the OQL world,
    not next to it.
  - Backend.Postgres is still on the roadmap for storage (OQL
    relational projection in cloud cells, user-owned PG). Just not
    motivated by Steampipe.
  - The Oql.Compiler / Oql.Index / Backend.Sqlite pipeline is
    unchanged. SaaS plugins are a parallel query path — they don't
    flow through the SQL compiler.

# Related plans

  - `BYOD-PLAN.org` — Backend.{Sqlite,Postgres,Workbook} layer. The
    Steampipe section there is superseded by this doc; will be
    edited in a follow-up commit.
  - `WORKBOOK-AS-BACKEND.org` — workbook as Database.Backend peer.
    Unchanged.
  - `OQL-CASE-STUDIES.org` — case studies. Several of them (e.g.
    cross-team coordination, agentic dispatch) naturally extend to
    SaaS plugins once the first plugins land.
