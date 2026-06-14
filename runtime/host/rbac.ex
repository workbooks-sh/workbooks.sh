defmodule Workbooks.RBAC do
  @moduledoc """
  Phase 4 — **Multi-level RBAC**. The ONE function (`can?/3`) that decides whether a
  member may perform a capability on a resource, composing three layers so the rule
  can't diverge across surfaces:

    1. **Tenant wall (outer floor).** Same-tenant by default; a cross-tenant request is
       DENIED unless an explicit grant covers it (a shared-folder grant) or the member
       is a PLATFORM admin doing a `:view` (wb-g1yo.5). This delegates the same-tenant
       test to the canonical `Workbooks.Tenant.visible?/2` — RBAC refines that wall, it
       never replaces it.
    2. **Role → capability** within the tenant: owner ⊃ admin ⊃ member ⊃ viewer.
    3. **Level intersection** (nexus ∩ toolkit ∩ workbook): a resource may carry an
       `:enclosing` resource; you can act on the inner resource only if you can ALSO
       `:view` every enclosing level. So effective access = your capability at the
       resource, gated by visibility up the whole containment chain — the minimum, not
       the maximum.

  Pure + fail-closed: an unknown role, a nil subject/tenant, or a missing field denies.
  Roles come from `Workbooks.ControlPlane` (the runtime's own registry, not the JWT).

  ## Shapes
    * subject  — `%{tenant, user_id, role, platform_admin?}` (build with `subject/2`)
    * resource — `%{tenant: owner, level: :nexus|:toolkit|:workbook|:folder, id,
                    grant: nil | :read | :draft, enclosing: nil | resource}`
    * capability — `:view | :edit | :share | :manage | :delete | :manage_roles`
  """

  alias Workbooks.ControlPlane

  @roles ~w(owner admin member viewer)a

  # role → the capabilities it grants WITHIN its tenant. Strictly nested.
  @caps_by_role %{
    owner: ~w(view edit share manage delete manage_roles)a,
    admin: ~w(view edit share manage)a,
    member: ~w(view edit)a,
    viewer: ~w(view)a
  }

  # an explicit cross-tenant grant → the capabilities it confers on THAT resource.
  @caps_by_grant %{read: ~w(view)a, draft: ~w(view edit)a}

  @doc "Known roles, most→least privileged."
  def roles, do: @roles

  @doc "Capabilities a role grants within its tenant (for surfacing the matrix)."
  def capabilities(role) when is_atom(role), do: Map.get(@caps_by_role, role, [])
  def capabilities(role) when is_binary(role), do: capabilities(to_role(role))

  @doc """
  Resolve a subject from `tenant` + `user_id`, reading the role from the registry.
  Default role = `:member`, EXCEPT a member whose `user_id == tenant` (the single-
  tenant/desktop/dev identity, and the tenant's creating principal) defaults to
  `:owner` so local flows are never locked out. `platform_admin?` from the `"*"` row.
  """
  def subject(tenant, user_id) when is_binary(tenant) and is_binary(user_id) do
    role =
      case ControlPlane.role_of(tenant, user_id) do
        nil -> if user_id == tenant, do: :owner, else: :member
        r -> to_role(r)
      end

    %{tenant: tenant, user_id: user_id, role: role, platform_admin?: ControlPlane.platform_admin?(user_id)}
  end

  def subject(_, _), do: nil

  # max containment depth — a decision engine must never recurse on caller-shaped
  # data unbounded (a self-referential `:enclosing` would loop). Eight levels is far
  # beyond nexus⊃toolkit⊃workbook; anything deeper denies.
  @max_depth 8

  @doc """
  May `subject` perform `capability` on `resource`? Pure, fail-closed. See moduledoc
  for the three composed layers.
  """
  def can?(subject, capability, resource), do: decide(subject, capability, resource, 0)

  defp decide(%{tenant: st, role: role, platform_admin?: padmin} = subject, cap, %{tenant: rt} = resource, depth)
       when is_binary(st) and is_atom(cap) and depth <= @max_depth do
    base =
      cond do
        # SAME tenant only — both sides a definite binary. A decision engine must not
        # grandfather a nil/absent owner (that auto-passes the caller's full role); a
        # resource with no concrete tenant is denied here.
        is_binary(rt) and rt == st ->
          cap in Map.get(@caps_by_role, role, [])

        # platform admin may VIEW across tenants (read-only), nothing more
        cap == :view and padmin ->
          true

        # an explicit cross-tenant grant confers exactly its mode's capabilities
        not is_nil(resource[:grant]) ->
          cap in Map.get(@caps_by_grant, resource[:grant], [])

        true ->
          false
      end

    # level intersection: must be able to VIEW every enclosing level too
    base and enclosing_ok?(subject, resource[:enclosing], depth + 1)
  end

  defp decide(_, _, _, _), do: false

  defp enclosing_ok?(_subject, nil, _depth), do: true
  defp enclosing_ok?(subject, parent, depth) when is_map(parent), do: decide(subject, :view, parent, depth)
  defp enclosing_ok?(_, _, _), do: false

  # Normalize a role string to a known atom; anything unknown → :viewer (least power,
  # fail-closed — never silently grants more than "view").
  defp to_role(r) when is_binary(r) do
    case r do
      "owner" -> :owner
      "admin" -> :admin
      "member" -> :member
      _ -> :viewer
    end
  end
end
