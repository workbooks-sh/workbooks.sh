defmodule Nexus.Platform do
  @moduledoc """
  The hosted control-plane HTTP API — `/api/platform/*`, the surface the cloud dashboard calls
  (nexus fleet CRUD + wake/sleep, usage, storage, workspaces, identity). Mounted by `Nexus.Server`
  via `forward "/api/platform"`, but ONLY answers when this nexus runs in the control-plane role
  (`WB_CONTROL_PLANE`) — otherwise 404, indistinguishable from a tenant runtime.

  **Security:** `org = conn.assigns[:tenant]`, set upstream by `Nexus.Auth.Cloud` from the caller's
  native session / PAT. `require_org` REFUSES to serve under `Nexus.Auth.None` (no real identity → no platform
  access), and every handler scopes to `org` through `Nexus.ControlPlane`, whose `{org, kind, id}`
  keying makes cross-org reads structurally impossible. Body input is whitelisted (name/region/plan,
  name/icon/nexus_id) — org, secrets, image, and the Fly org are pinned server-side, never caller
  input.

  Fleet provisioning here is registry-backed (state transitions); the real Fly machine provisioner
  layers onto the same contract next.
  """
  use Plug.Router
  alias Nexus.ControlPlane, as: CP
  alias Nexus.ControlPlane.Env

  plug(:require_control_plane)
  plug(:match)
  plug(:require_org)
  # DEFAULT-DENY every control-plane write at admin+ (fix wb-k5i0/wb-qfvt) — one central gate so a new
  # mutating route can't silently ship role-blind. Reads (GET, except /env/:id/reveal which carries its
  # own admin gate) and the member allowlist below pass through.
  plug(:require_admin_writes)
  plug(:dispatch)

  # ── nexuses ─────────────────────────────────────────────────────────────────────────────────
  get "/nexuses" do
    # One nexus per org — "the nexus IS the org". If the org hasn't provisioned a separate machine, the
    # nexus SERVING this request IS the org's nexus, so self-report it. Never an empty fleet for a real
    # org: you're always looking at your own nexus. (A provisioned fleet takes precedence.)
    nexuses =
      case CP.list(org(conn), :nexus) do
        [] -> [self_nexus(conn)]
        list -> Enum.map(list, &nexus_view/1)
      end

    j(conn, 200, %{nexuses: nexuses})
  end

  # One nexus PER ORG — the nexus IS the org (a Fly machine / scale-group). You
  # scale the one nexus (pricing tier), you don't create a second; more separation
  # means a new org. Refuse a second provision rather than fan out machines.
  post "/nexuses" do
    case CP.list(org(conn), :nexus) do
      [nx | _] ->
        j(conn, 409, %{error: "one nexus per organization — scale this one instead, or create a new org", nexus: nexus_view(nx)})

      [] ->
        case Nexus.Provisioner.provision(org(conn), provision_opts(read(conn))) do
          {:ok, nx} -> j(conn, 201, nexus_view(nx))
          {:error, reason} -> j(conn, 422, %{error: reason_str(reason)})
        end
    end
  end

  get "/nexuses/:id" do
    case CP.get(org(conn), :nexus, conn.params["id"]) do
      {:ok, nx} ->
        j(conn, 200, nexus_view(nx))

      {:error, :not_found} ->
        # The self-reported serving nexus (empty registry) has no registry row — resolve it here so the
        # detail view works for the org's own nexus.
        if conn.params["id"] == self_nexus_id() and CP.list(org(conn), :nexus) == [],
          do: j(conn, 200, self_nexus(conn)),
          else: j(conn, 404, %{error: "not found"})
    end
  end

  delete "/nexuses/:id" do
    admin_only(conn, fn ->
      case Nexus.Provisioner.teardown(conn.params["id"], org(conn)) do
        {:ok, _} -> j(conn, 200, %{ok: true})
        {:error, :not_found} -> j(conn, 404, %{error: "not found"})
        {:error, reason} -> j(conn, 422, %{error: reason_str(reason)})
      end
    end)
  end

  # Rename the org's nexus (admin action in the dashboard). Whitelisted to name/friendly — id, org,
  # plan, Fly identity are never caller-mutable. Org-scoped, so a foreign nexus is a 404.
  patch "/nexuses/:id" do
    attrs = read(conn) |> decode() |> Map.take(["name", "friendly"]) |> atomize()

    case CP.update(org(conn), :nexus, conn.params["id"], attrs) do
      {:ok, nx} -> j(conn, 200, nexus_view(nx))
      {:error, :not_found} -> j(conn, 404, %{error: "not found"})
    end
  end

  post "/nexuses/:id/wake", do: lifecycle(conn, &Nexus.Provisioner.wake/2)
  post "/nexuses/:id/sleep", do: lifecycle(conn, &Nexus.Provisioner.sleep/2)

  # ── usage / identity / storage ───────────────────────────────────────────────────────────────
  # Usage + capacity for the org's single nexus: RAM + storage vs the tier ceiling
  # (Nexus.Pricing), plus the top consumers to shed when a dial runs hot. Auto-scale
  # lives within the ceiling; crossing it is a paid scale-up. (Showcase backend —
  # the per-nexus reading is derived; the limits/thresholds/billing are real.)
  get "/usage" do
    # Real measurement of the serving nexus when the org has no separately-provisioned machine (the
    # one-per-org case) — RAM/storage metered for real (Capacity reads /proc + the data dir), against
    # the tier matching the actual machine size. Otherwise report the org's provisioned nexus.
    nx =
      case CP.list(org(conn), :nexus) do
        [] -> %{id: self_nexus_id(), plan: self_tier_id(), state: "running", self: true}
        [n | _] -> n
      end

    j(conn, 200, Nexus.Capacity.report(nx))
  end

  # The tier ladder (for the dashboard's scale-up UI) — limits + price + domains gate.
  get "/tiers" do
    j(conn, 200, %{tiers: Nexus.Pricing.tiers()})
  end

  # AI credits: remaining balance, spend-this-month, and the monthly cap. The money boundary
  # (Nexus.Inference.Admission) already enforces these; this READS them for the dashboard.
  get "/credits" do
    j(conn, 200, Nexus.Inference.Admission.status(org(conn)))
  end

  # Add credit — an admin grant or a settled top-up. (Self-serve top-up buys through Polar, which settles
  # here via the webhook; this is also the support/comp path.) Admin-gated like every control-plane write.
  post "/credits/topup" do
    admin_only(conn, fn ->
      amount = decode(read(conn))["amount"]

      if is_number(amount) and amount > 0 do
        case Nexus.Inference.Admission.credit(org(conn), amount / 1) do
          {:ok, bal} -> j(conn, 200, %{ok: true, balance: bal})
          _ -> j(conn, 422, %{error: "top-up failed"})
        end
      else
        j(conn, 422, %{error: "amount must be a positive number"})
      end
    end)
  end

  # Plan subscription — start a Polar checkout for `plan`. The plan→product map is config
  # (`POLAR_PRODUCT_<plan>` in Secrets); the card-on-file is reused via `external_customer_id`.
  # Fully graceful: no token / no product ⇒ 503 with a clear next step. The webhook settles the plan.
  post "/billing/checkout" do
    admin_only(conn, fn ->
      plan = decode(read(conn))["plan"]
      product = is_binary(plan) && Nexus.Secrets.get("POLAR_PRODUCT_" <> plan)
      id = conn.assigns[:identity] || %{}

      cond do
        not is_binary(plan) ->
          j(conn, 422, %{error: "plan required"})

        not is_binary(product) ->
          j(conn, 503, %{error: "billing not configured", detail: "set POLAR_ACCESS_TOKEN + POLAR_PRODUCT_#{plan} in Secrets"})

        true ->
          # metadata.tier is what the existing polar_webhook settlement (settle_polar) reads to activate
          # the plan; external_customer_id binds the tenant Polar-side (settlement trusts THAT, not metadata).
          opts = [products: [product], external_customer_id: org(conn), customer_email: checkout_email(id[:email]),
                  success_url: billing_return(conn), metadata: %{org: org(conn), tier: plan}]

          case Nexus.Polar.create_checkout(opts) do
            {:ok, %{url: url}} -> j(conn, 200, %{url: url})
            {:error, :not_configured} -> j(conn, 503, %{error: "billing not configured", detail: "set POLAR_ACCESS_TOKEN in Secrets"})
            {:error, reason} -> j(conn, 422, %{error: "checkout failed", detail: inspect(reason)})
          end
      end
    end)
  end

  # Buy AI credits — a custom-amount Polar checkout. The webhook (settle_polar) reads
  # metadata.purpose=="inference_credit" + metadata.credit to credit the balance after payment.
  post "/credits/checkout" do
    admin_only(conn, fn ->
      amount = decode(read(conn))["amount"]
      product = Nexus.Secrets.get("POLAR_PRODUCT_credits")
      id = conn.assigns[:identity] || %{}

      cond do
        not (is_number(amount) and amount > 0) ->
          j(conn, 422, %{error: "amount must be a positive number"})

        not is_binary(product) ->
          j(conn, 503, %{error: "credit purchases not configured", detail: "set POLAR_ACCESS_TOKEN + POLAR_PRODUCT_credits in Secrets"})

        true ->
          opts = [products: [product], amount: round(amount * 100), external_customer_id: org(conn),
                  customer_email: checkout_email(id[:email]), success_url: billing_return(conn),
                  metadata: %{org: org(conn), purpose: "inference_credit", credit: amount}]

          case Nexus.Polar.create_checkout(opts) do
            {:ok, %{url: url}} -> j(conn, 200, %{url: url})
            {:error, :not_configured} -> j(conn, 503, %{error: "credit purchases not configured", detail: "set POLAR_ACCESS_TOKEN in Secrets"})
            {:error, reason} -> j(conn, 422, %{error: "checkout failed", detail: inspect(reason)})
          end
      end
    end)
  end

  # Current subscription (set by the polar_webhook settlement at (org, :billing, "subscription")).
  get "/billing/subscription" do
    case Nexus.ControlPlane.get(org(conn), :billing, "subscription") do
      {:ok, sub} -> j(conn, 200, sub)
      _ -> j(conn, 200, %{tier: nil, status: "none"})
    end
  end

  # Auto-top-up preference — recharge `amount` of AI credits from the card on file
  # when the balance drops below `threshold`. Stored at (org,:billing,autotopup).
  # The Admission money boundary reads this on a low-balance check; the actual
  # off-session Polar charge rides the customer's saved payment method.
  get "/billing/autotopup" do
    case Nexus.ControlPlane.get(org(conn), :billing, "autotopup") do
      {:ok, cfg} -> j(conn, 200, cfg)
      _ -> j(conn, 200, %{enabled: false, threshold: 0, amount: 0})
    end
  end

  post "/billing/autotopup" do
    admin_only(conn, fn ->
      b = decode(read(conn))
      n = fn v -> if is_number(v), do: v / 1, else: 0.0 end
      cfg = %{enabled: b["enabled"] == true, threshold: n.(b["threshold"]), amount: n.(b["amount"])}
      Nexus.ControlPlane.put(org(conn), :billing, "autotopup", cfg)
      j(conn, 200, Map.put(cfg, :ok, true))
    end)
  end

  defp billing_return(conn) do
    base = if conn.port in [80, 443], do: "#{conn.scheme}://#{conn.host}", else: "#{conn.scheme}://#{conn.host}:#{conn.port}"
    base <> "/cloud/"
  end

  # Only pre-fill the checkout email when it's a real address — Polar rejects reserved-domain emails
  # (RFC 6761: .test/.local/.example/.invalid/localhost). Reserved ⇒ nil ⇒ Polar collects it at checkout.
  defp checkout_email(email) when is_binary(email) do
    domain = email |> String.split("@") |> List.last() |> to_string() |> String.downcase()

    reserved? =
      String.ends_with?(domain, [".test", ".local", ".localhost", ".invalid", ".example"]) or
        domain in ["example.com", "example.org", "example.net", "localhost"]

    if reserved?, do: nil, else: email
  end

  defp checkout_email(_), do: nil

  # (Marketing/upsell logic is NOT a runtime concern — THE LINE. It lives in our own workbook
  # `dogfood/marketing` as a `server :upsell` block, served like any workbook via its live source.)

  get "/me" do
    id = conn.assigns[:identity] || %{}
    user_id = id[:user]
    # One org per user (native auth). Drop the WorkOS lookup — orgs is the user's own org.
    o = org(conn)
    orgs = if is_binary(o), do: [%{id: o, name: org_name(o)}], else: []
    # The signed-in user's role(s) in this org (owner|admin|member|viewer). The dashboard gates its
    # context-menu actions on this via WB.can — hiding what the role can't do. Server routes remain the
    # real authority (Nexus.Auth.Guard); this is the UX mirror of it.
    roles = id[:roles] || []
    # Absence ⇒ least privilege, NOT owner: an identity that reaches /me with no roles (a PAT minted with
    # a blank role, a legacy session) must read as `viewer`, never `owner` — matching Nexus.Auth.role/1's
    # own viewer default. A fail-open owner here unhid owner-only actions in the dashboard. (red-team wb-gexp)
    role = List.first(roles) || "viewer"
    # AUTHORITATIVE identity — look up the account by id so name/email/avatar are
    # real even when the caller is a PAT (a wbk_ token carries user_id + roles but
    # NOT the profile). Falls back to the session identity, then blank. This is
    # what the AutoPoet desktop syncs into onboarding (name pre-fill + avatar).
    acct = is_binary(user_id) && Nexus.Auth.Accounts.get(user_id) || %{}

    j(conn, 200, %{
      user: %{
        id: user_id,
        name: acct[:name] || id[:name] || "",
        email: acct[:email] || id[:email] || "",
        avatar: acct[:avatar] || id[:avatar]
      },
      active_org: o,
      orgs: orgs,
      role: role,
      roles: roles
    })
  end

  get "/storage" do
    case CP.list(org(conn), :nexus) do
      # No provisioned fleet → the serving nexus's REAL object store: one bucket per mounted surface,
      # sizes from the on-disk footprint (the same primitive the server :cloud live source reports).
      [] ->
        buckets =
          for {name, root} <- Application.get_env(:nexus, :mounts, []), name != "" do
            bytes = dir_bytes(root)
            %{name: name, nexus: self_nexus_id(), objects: count_files(root), size: human(bytes), egress: "$0.00", bytes: bytes}
          end

        total = Enum.reduce(buckets, 0, &(&1.bytes + &2))
        j(conn, 200, %{totalBytes: total, totalSize: human(total),
          buckets: buckets |> Enum.sort_by(& &1.bytes, :desc) |> Enum.map(&Map.delete(&1, :bytes))})

      list ->
        buckets = Enum.map(list, fn nx -> %{name: "#{nx.id}-storage", nexus: nx.id, objects: nil, size: "—", egress: "$0.00"} end)
        j(conn, 200, %{totalBytes: 0, totalSize: "0 GB", buckets: buckets})
    end
  end

  # The DATA SYSTEMS breakdown (disk / db / repos / caches, split by the durable boundary). Real du of
  # the serving nexus's own volume; a provisioned remote reports empty until its usage channel lands.
  get "/data" do
    report =
      case CP.list(org(conn), :nexus) do
        [] -> Nexus.DataSystems.report()
        _ -> %{volume: %{used: "—", durable: "—", ephemeral: "—"}, systems: [], remote: true}
      end

    j(conn, 200, report)
  end

  # Data explorer: the org's tables (resources with rows) + their rows. Tenant-partitioned in the store,
  # so an org only ever sees its own data.
  get "/data/tables" do
    j(conn, 200, %{tables: Nexus.Store.Sqlite.tables(org(conn))})
  end

  get "/data/tables/:name/rows" do
    conn = fetch_query_params(conn)

    limit =
      case Integer.parse(conn.query_params["limit"] || "100") do
        {n, _} when n > 0 and n <= 500 -> n
        _ -> 100
      end

    j(conn, 200, %{rows: Nexus.Store.Sqlite.rows(name, org(conn), limit)})
  end

  # ── CLI access tokens (minted for the org; the `work` CLI sends them as Bearer) ────────────────
  # The dashboard (native session) mints these; the headless CLI then authenticates
  # with one via Nexus.Auth.Cloud — no browser session needed.
  post "/tokens/mint" do
    name = decode(read(conn))["name"] || "cli"
    id = conn.assigns[:identity] || %{}
    # The PAT inherits the minter's server-derived role (and id) so the CLI acts with real authority.
    j(conn, 201, Nexus.ControlPlane.Token.mint(org(conn), name, role: Nexus.Auth.role(conn), user: id[:user]))
  end

  get "/tokens" do
    j(conn, 200, %{tokens: Nexus.ControlPlane.Token.list(org(conn))})
  end

  delete "/tokens/:id" do
    Nexus.ControlPlane.Token.revoke(org(conn), conn.params["id"])
    j(conn, 200, %{ok: true})
  end

  # ── org members + invitations (native auth — Nexus.Auth.Accounts, no third-party IdP) ──────────
  # The org roster is the org's users; invitations are pending until the invitee signs up (then they
  # join THIS org with the invited role). Generic runtime mechanism — any deployer's org gets it.
  get "/members" do
    o = org(conn)

    members =
      Enum.map(Nexus.Auth.Accounts.list_org(o), fn m ->
        name = if m.name == "", do: o |> to_string() |> then(fn _ -> hd(String.split(m.email, "@")) end), else: m.name
        %{id: m.id, name: name, email: m.email, role: m.role, lastActive: nil}
      end)

    pending = Enum.map(Nexus.Auth.Accounts.list_invites(o), &%{id: &1.id, email: &1.email})
    j(conn, 200, %{workspace: org_name(o), members: members, pending: pending})
  end

  post "/members/invite" do
    admin_only(conn, fn ->
      body = decode(read(conn))
      email = body |> Map.get("email", "") |> to_string() |> String.trim()
      role = body |> Map.get("role", "member") |> to_string()

      # Cap the invited role at the CALLER's own rank: an admin must not be able to mint an owner (or
      # any role above their own) — admin_only gates the route, but without this an admin could invite
      # role:"owner" and manufacture a higher-privileged account. (red-team wb-wbm6)
      caller_rank = Nexus.Auth.Accounts.rank(Nexus.Auth.role(conn))

      cond do
        email == "" ->
          j(conn, 400, %{error: "Email is required"})

        Nexus.Auth.Accounts.rank(role) > caller_rank ->
          j(conn, 403, %{error: "cannot invite a role above your own"})

        true ->
        case Nexus.Auth.Accounts.invite(org(conn), email, role, (conn.assigns[:identity] || %{})[:user]) do
          {:ok, _inv} -> j(conn, 200, %{invited: email})
          {:error, :bad_email} -> j(conn, 400, %{error: "Enter a valid email"})
          _ -> j(conn, 400, %{error: "Invite failed"})
        end
      end
    end)
  end

  delete "/members/:id" do
    admin_only(conn, fn ->
      case Nexus.Auth.Accounts.remove_member(org(conn), conn.params["id"]) do
        :ok -> j(conn, 200, %{removed: true})
        {:error, :last_owner} -> j(conn, 400, %{error: "Can't remove the org's only owner"})
        _ -> j(conn, 400, %{error: "Remove failed"})
      end
    end)
  end

  post "/invitations/:id/revoke" do
    admin_only(conn, fn ->
      Nexus.Auth.Accounts.revoke_invite(org(conn), conn.params["id"])
      j(conn, 200, %{revoked: true})
    end)
  end

  # ── custom domains (paid-tier, owner-verified — share from your domain, not ours) ──────────────
  # Add → TXT challenge; verify → resolve the TXT + request the Fly cert; the record
  # is org-scoped and the host is globally unique. See Nexus.ControlPlane.Domain.
  get "/domains" do
    j(conn, 200, %{domains: Nexus.ControlPlane.Domain.list(org(conn))})
  end

  post "/domains" do
    admin_only(conn, fn ->
      case Nexus.ControlPlane.Domain.add(org(conn), decode(read(conn))["host"]) do
        {:ok, view} -> j(conn, 201, view)
        {:error, reason} -> j(conn, domain_status(reason), %{error: domain_error(reason)})
      end
    end)
  end

  get "/domains/:id" do
    case Nexus.ControlPlane.Domain.get(org(conn), conn.params["id"]) do
      {:ok, view} -> j(conn, 200, view)
      {:error, :not_found} -> j(conn, 404, %{error: "not found"})
    end
  end

  post "/domains/:id/verify" do
    admin_only(conn, fn ->
      case Nexus.ControlPlane.Domain.verify(org(conn), conn.params["id"]) do
        {:ok, view} -> j(conn, 200, view)
        {:error, :txt_not_found} -> j(conn, 422, %{error: "TXT challenge not found — add the record and allow DNS to propagate, then retry"})
        {:error, :not_found} -> j(conn, 404, %{error: "not found"})
        {:error, reason} -> j(conn, 422, %{error: domain_error(reason)})
      end
    end)
  end

  delete "/domains/:id" do
    admin_only(conn, fn ->
      case Nexus.ControlPlane.Domain.remove(org(conn), conn.params["id"]) do
        :ok -> j(conn, 200, %{ok: true})
        {:error, :not_found} -> j(conn, 404, %{error: "not found"})
      end
    end)
  end

  # ── workspaces (free, no compute — logical org divisions) ──────────────────────────────────────
  get "/workspaces" do
    org = org(conn)
    # Declared workspaces (curated folders, from the deploy config) + any per-org UI emoji/name
    # overrides + user-created workspaces. Runtime ships none — the deployer declares them.
    overrides = Map.new(CP.list(org, :ws_override), &{&1.id, &1})

    declared =
      Enum.map(Nexus.Config.workspaces(), fn w ->
        o = overrides[w.id] || %{}
        %{id: w.id, name: o[:name] || w.name, icon: o[:icon] || w.icon, nexus_id: self_nexus_id(), surface: true}
      end)

    created = Enum.map(CP.list(org, :workspace), &ws_view/1)
    j(conn, 200, %{workspaces: declared ++ created})
  end

  post "/workspaces" do
    org = org(conn)
    %{name: name, icon: icon, nexus_id: nexus_id} = workspace_params(read(conn))

    cond do
      name in [nil, ""] -> j(conn, 422, %{error: "name required"})
      true ->
        id = "ws_" <> rand()
        {:ok, ws} = CP.put(org, :workspace, id, %{name: name, icon: icon, nexus_id: nexus_id})
        provision_workspace_repo(id)
        j(conn, 201, ws_view(ws))
    end
  end

  patch "/workspaces/:id" do
    org = org(conn)
    attrs = read(conn) |> decode() |> Map.take(["name", "icon"]) |> atomize()

    id = conn.params["id"]

    case CP.update(org, :workspace, id, attrs) do
      {:ok, ws} ->
        j(conn, 200, ws_view(ws))

      {:error, :not_found} ->
        # A declared (deploy-config) workspace has no CP row — persist a per-org OVERRIDE (so the UI
        # emoji picker / rename sticks), merged over the declared name/emoji.
        case Enum.find(Nexus.Config.workspaces(), &(&1.id == id)) do
          nil ->
            j(conn, 404, %{error: "not found"})

          decl ->
            prev = case CP.get(org, :ws_override, id) do {:ok, o} -> o; _ -> %{} end
            merged = prev |> Map.merge(attrs) |> Map.put(:id, id)
            {:ok, o} = CP.put(org, :ws_override, id, merged)
            j(conn, 200, %{id: id, name: o[:name] || decl.name, icon: o[:icon] || decl.icon, nexus_id: self_nexus_id(), surface: true})
        end
    end
  end

  delete "/workspaces/:id" do
    # Full cascade: remove the working tree + bare repo + CP record + unmount — not just the CP row.
    # (A CP-only delete left the on-disk workspace serving — the leftover-`marketing` pollution.)
    Nexus.Workspaces.deprovision(conn.params["id"], org(conn))
    j(conn, 200, %{ok: true})
  end

  # ── env vars (encrypted-at-rest, org+workspace-scoped team secrets) ─────────────────────────────
  # All org-scoped via Nexus.ControlPlane.Env (cross-org physically impossible). The list/views are
  # REDACTED — the plaintext only ever leaves via the explicit /reveal action. A missing master key
  # fails closed → 503 (values are never stored unencrypted), surfaced by `env_fail`.
  get "/env" do
    q = fetch_query_params(conn).query_params
    scope = blank_to_nil(q["scope"])
    workspace = blank_to_nil(q["workspace"])

    # Listing the WHOLE org/nexus secret inventory must be admin-only — previously any authenticated
    # viewer could enumerate every secret's name + scope (recon for targeted attacks). The only legit
    # non-admin caller is the workspace Secrets page, which always passes ?workspace=<id> and manages
    # that workspace's own env (cross-workspace membership enforcement is the seam-1.2 reference
    # monitor). So: a `workspace`-scoped list stays member-accessible; an unscoped list requires admin.
    # (red-team wb-cfk7)
    gate = if workspace, do: & &1.(), else: &admin_only(conn, &1)

    gate.(fn ->
      env = Env.list(org(conn), workspace)
      env = if scope, do: Enum.filter(env, &(&1.scope == scope)), else: env
      j(conn, 200, %{env: env})
    end)
  end

  post "/env" do
    admin_only(conn, fn ->
      m = decode(read(conn))
      attrs = %{
        name: m["name"], value: m["value"], scope: m["scope"],
        workspace_id: m["workspace_id"], package_name: m["package_name"]
      }

      # A `nexus`-scoped secret must be STORED under the same org the runtime READS it from —
      # `Nexus.Secrets` resolves nexus secrets via `Nexus.Auth.nexus_org/0` (the nexus-owning org), not
      # the requesting admin's tenant. Writing it under `org(conn)` meant a non-founding-org admin's
      # nexus secret silently never reached the runtime ("saved but not applied"). Align write→read:
      # nexus scope ⇒ nexus_org(); per-tenant scopes (user/workspace/package) stay under the caller's
      # org. (red-team wb-go7c)
      case Env.create(env_storage_org(conn, attrs.scope), attrs) do
        {:ok, view} -> j(conn, 201, view)
        {:error, reason} -> env_fail(conn, reason)
      end
    end)
  end

  get "/env/:id/reveal" do
    admin_only(conn, fn ->
      case Env.reveal(org(conn), conn.params["id"]) do
        {:ok, value} -> j(conn, 200, %{value: value})
        {:error, :not_found} -> j(conn, 404, %{error: "not found"})
        {:error, reason} -> env_fail(conn, reason)
      end
    end)
  end

  patch "/env/:id" do
    admin_only(conn, fn ->
      m = decode(read(conn))
      attrs = %{name: m["name"], value: m["value"]}

      case Env.update(org(conn), conn.params["id"], attrs) do
        {:ok, view} -> j(conn, 200, view)
        {:error, :not_found} -> j(conn, 404, %{error: "not found"})
        {:error, reason} -> env_fail(conn, reason)
      end
    end)
  end

  delete "/env/:id" do
    admin_only(conn, fn ->
      :ok = Env.delete(org(conn), conn.params["id"])
      j(conn, 200, %{ok: true})
    end)
  end

  match _ do
    j(conn, 404, %{error: "not found"})
  end

  # ── guards ─────────────────────────────────────────────────────────────────────────────────
  defp require_control_plane(conn, _) do
    if CP.enabled?(), do: conn, else: conn |> send_resp(404, "not found") |> halt()
  end

  # No real org identity → no platform. Refuses Nexus.Auth.None (everyone would be one tenant = no
  # isolation), so the control-plane can never accidentally run wide-open.
  defp require_org(conn, _) do
    if is_binary(conn.assigns[:tenant]) and Nexus.Auth.multi?() do
      conn
    else
      conn |> put_resp_content_type("application/json") |> send_resp(403, Jason.encode!(%{error: "forbidden"})) |> halt()
    end
  end

  # Mutations any org MEMBER may perform (not admin-only): minting a CLI PAT — it inherits the minter's
  # OWN server-derived role, so no escalation. Everything else that writes requires admin.
  @member_writes [["tokens", "mint"]]

  defp require_admin_writes(conn, _) do
    cond do
      conn.method not in ["POST", "PUT", "PATCH", "DELETE"] -> conn
      conn.path_info in @member_writes -> conn
      admin?(conn) -> conn
      true -> conn |> put_resp_content_type("application/json") |> send_resp(403, Jason.encode!(%{error: "admin required"})) |> halt()
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────────────────────────
  defp org(conn), do: conn.assigns[:tenant]

  # Storage org for an env secret: a `nexus`-scoped secret lives under the nexus-owning org so the
  # runtime's `Nexus.Secrets` read (via `Nexus.Auth.nexus_org/0`) finds it; everything else is the
  # caller's tenant. (red-team wb-go7c — write/read org alignment.)
  defp env_storage_org(conn, "nexus"), do: Nexus.Auth.nexus_org() || org(conn)
  defp env_storage_org(conn, _scope), do: org(conn)

  # Sensitive control-plane mutations (secrets, members, domains, nexus delete) require admin+ — not any
  # org member (fix wb-qfvt). require_org proves you're IN the org; this proves you may ADMINISTER it.
  defp admin?(conn), do: Nexus.Auth.role_at_least?(Nexus.Auth.role(conn), "admin")
  defp admin_only(conn, fun), do: if(admin?(conn), do: fun.(), else: j(conn, 403, %{error: "admin required"}))
  # Display name for an org — set by onboarding (next increment); nil ⇒ the dashboard falls back to
  # a generic "your workspace" label, exactly as the source does on an unnamed org.
  defp org_name(_o), do: nil

  defp lifecycle(conn, fun) do
    case fun.(conn.params["id"], org(conn)) do
      {:ok, nx} -> j(conn, 200, nexus_view(nx))
      {:error, :not_found} -> j(conn, 404, %{error: "not found"})
      {:error, reason} -> j(conn, 422, %{error: reason_str(reason)})
    end
  end

  # No master key → fail closed with 503 (a deploy-config error, not the caller's fault); other env
  # errors are caller validation → 422. Never leak crypto detail beyond the reason atom.
  defp env_fail(conn, :no_master_key),
    do: j(conn, 503, %{error: "env store unavailable: WB_ENV_MASTER_KEY not configured"})

  defp env_fail(conn, reason), do: j(conn, 422, %{error: reason_str(reason)})

  defp reason_str(r) when is_atom(r), do: Atom.to_string(r)
  defp reason_str(r), do: inspect(r)

  # Custom-domain errors → HTTP status + a buyer-facing message.
  defp domain_status(:tier_locked), do: 402
  defp domain_status(:host_taken), do: 409
  defp domain_status(:no_nexus), do: 409
  defp domain_status(_), do: 422

  defp domain_error(:tier_locked), do: "custom domains need a paid plan (Team or higher) — scale up to bind one"
  defp domain_error(:host_taken), do: "that host is already bound to another organization"
  defp domain_error(:reserved_host), do: "that host is reserved"
  defp domain_error(:invalid_host), do: "enter a valid domain like apps.yourcompany.com"
  defp domain_error(:no_nexus), do: "provision your nexus before binding a domain"
  defp domain_error(r), do: reason_str(r)

  defp nexus_view(nx) do
    %{
      id: nx.id,
      name: nx[:name] || nx.id,
      region: nx[:region] || "",
      plan: nx[:plan] || "starter",
      state: map_state(nx[:state]),
      url: nx[:url] || ""
    }
  end

  # The nexus serving this request, as the org's own nexus (one-per-org model). Identity comes from
  # the deploy's configured nexus name/friendly (set in Nexus.Server) — generic, nothing org-specific.
  defp self_nexus(conn) do
    name = Application.get_env(:nexus, :nexus_name, "")
    friendly = Application.get_env(:nexus, :nexus_friendly, "")
    id = if name == "", do: "nexus", else: name

    %{
      id: id,
      name: if(friendly == "", do: id, else: friendly),
      icon: Nexus.Config.nexus_emoji(),
      region: System.get_env("FLY_REGION") || System.get_env("WB_FLY_REGION") || "",
      plan: self_tier_id(),
      state: "run",
      url: conn.host,
      # the serving nexus IS the org (no separate machine provisioned) — the dashboard shows it as the
      # workspace itself, not a separately-tearable agent machine.
      self: true
    }
  end

  defp self_nexus_id, do: (n = Application.get_env(:nexus, :nexus_name, "")) == "" && "nexus" || n

  # The tier whose RAM ceiling matches the actual machine — the machine size IS the plan you're on
  # (closest by RAM). No guessing a default: a 2 GB machine reads the 2 GB tier.
  defp self_tier_id do
    total = Nexus.Capacity.machine_total_mb()
    (Enum.min_by(Nexus.Pricing.tiers(), fn t -> abs((t[:ram_mb] || 0) - total) end) || Nexus.Pricing.default_tier()).id
  end

  # On-disk footprint of a mounted surface (bounded walk) — the same primitive the server :cloud
  # live source uses; honest, derived from what's actually on the volume.
  defp dir_bytes(root) do
    Path.wildcard(Path.join(root, "**/*")) |> Enum.filter(&File.regular?/1)
    |> Enum.reduce(0, fn f, acc -> acc + (File.stat!(f).size || 0) end)
  rescue
    _ -> 0
  end

  defp count_files(root), do: Path.wildcard(Path.join(root, "**/*")) |> Enum.count(&File.regular?/1)

  defp human(b) when b >= 1_073_741_824, do: "#{Float.round(b / 1_073_741_824, 2)} GB"
  defp human(b) when b >= 1_048_576, do: "#{Float.round(b / 1_048_576, 1)} MB"
  defp human(b) when b >= 1024, do: "#{div(b, 1024)} KB"
  defp human(b), do: "#{b} B"

  defp ws_view(ws), do: %{id: ws.id, name: ws[:name], icon: ws[:icon], nexus_id: ws[:nexus_id]}

  defp map_state("running"), do: "run"
  defp map_state("stopped"), do: "sleep"
  defp map_state(_), do: "build"

  defp provision_opts(body) do
    m = decode(body)

    []
    |> put_opt(:name, m["name"])
    |> put_opt(:region, m["region"])
    |> put_opt(:plan, m["plan"])
    |> put_opt(:provider, m["provider"])
  end

  defp put_opt(opts, _k, v) when v in [nil, ""], do: opts
  defp put_opt(opts, k, v), do: Keyword.put(opts, k, v)

  defp workspace_params(body) do
    m = decode(body)
    %{name: m["name"], icon: m["icon"], nexus_id: blank_to_nil(m["nexus_id"])}
  end

  defp blank_to_nil(v) when v in [nil, ""], do: nil
  defp blank_to_nil(v), do: v

  # Provision the workspace's bare git repo so it's immediately pushable (`git push <nexus>/git/<id>.git`).
  # Best-effort: never fail the workspace create if git is unavailable. The repo also auto-provisions on
  # first push (Nexus.GitHttp), so this just makes the remote exist eagerly.
  defp provision_workspace_repo(id) do
    bare = Nexus.Git.bare_path(Nexus.GitHttp.repos_root(), id)
    Nexus.Git.provision_remote(bare, Nexus.GitHttp.work_dir(id))
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp atomize(m), do: Map.new(m, fn {k, v} -> {String.to_existing_atom(k), v} end)

  defp read(conn) do
    case read_body(conn) do
      {:ok, body, _conn} -> body
      _ -> ""
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, %{} = m} -> m
      _ -> %{}
    end
  end

  defp rand, do: Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

  defp j(conn, status, body) do
    conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
  end
end
