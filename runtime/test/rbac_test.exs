defmodule Workbooks.RBACTest do
  @moduledoc """
  Phase 4 — Multi-level RBAC. Pins the three composed layers of `RBAC.can?/3`:
  the role→capability matrix, the tenant wall + cross-tenant grant / platform-admin
  escapes, and the nexus ∩ toolkit ∩ workbook level intersection. Everything is
  fail-closed: unknown role, cross-tenant without a grant, or a denied enclosing
  level all deny.
  """
  use ExUnit.Case, async: false

  alias Workbooks.{RBAC, ControlPlane}

  defp uniq(p), do: "#{p}-#{System.unique_integer([:positive])}"

  # a subject with an explicit role (bypassing the registry default) for matrix tests
  defp who(tenant, role), do: %{tenant: tenant, user_id: "u", role: role, platform_admin?: false}
  defp res(tenant, level, opts \\ []),
    do: Map.merge(%{tenant: tenant, level: level, id: "r"}, Map.new(opts))

  test "role → capability matrix is strictly nested" do
    t = "acme"
    nexus = res(t, :nexus)

    # owner: everything
    for cap <- ~w(view edit share manage delete manage_roles)a, do: assert RBAC.can?(who(t, :owner), cap, nexus)
    # admin: all but delete + manage_roles
    assert RBAC.can?(who(t, :admin), :manage, nexus)
    assert RBAC.can?(who(t, :admin), :share, nexus)
    refute RBAC.can?(who(t, :admin), :delete, nexus)
    refute RBAC.can?(who(t, :admin), :manage_roles, nexus)
    # member: view + edit only
    assert RBAC.can?(who(t, :member), :edit, nexus)
    refute RBAC.can?(who(t, :member), :share, nexus)
    refute RBAC.can?(who(t, :member), :manage, nexus)
    # viewer: view only
    assert RBAC.can?(who(t, :viewer), :view, nexus)
    refute RBAC.can?(who(t, :viewer), :edit, nexus)
  end

  test "unknown / malformed subject or role fails closed" do
    t = "acme"
    refute RBAC.can?(nil, :view, res(t, :nexus))
    refute RBAC.can?(%{tenant: t, role: :wizard, platform_admin?: false}, :view, res(t, :nexus))
    refute RBAC.can?(who(t, :member), :view, %{})
  end

  test "tenant wall: cross-tenant denied without a grant" do
    a = "acme"
    b = "beta"
    # an admin of A has no power over B's resource
    refute RBAC.can?(who(a, :admin), :view, res(b, :workbook))
    refute RBAC.can?(who(a, :owner), :edit, res(b, :folder))
  end

  test "platform admin may VIEW across tenants — and nothing more" do
    padmin = %{tenant: "acme", user_id: "root", role: :member, platform_admin?: true}
    assert RBAC.can?(padmin, :view, res("beta", :nexus))
    refute RBAC.can?(padmin, :edit, res("beta", :nexus))
    refute RBAC.can?(padmin, :delete, res("beta", :nexus))
  end

  test "explicit cross-tenant grant confers exactly its mode's capabilities" do
    recipient = who("beta", :member)
    read_folder = res("acme", :folder, grant: :read)
    draft_folder = res("acme", :folder, grant: :draft)

    assert RBAC.can?(recipient, :view, read_folder)
    refute RBAC.can?(recipient, :edit, read_folder)

    assert RBAC.can?(recipient, :view, draft_folder)
    assert RBAC.can?(recipient, :edit, draft_folder)
    # a grant never confers management/share/delete
    refute RBAC.can?(recipient, :share, draft_folder)
    refute RBAC.can?(recipient, :delete, draft_folder)
  end

  test "level intersection: denied if any enclosing level denies view" do
    t = "acme"
    # a workbook inside a nexus the member CAN view → edit allowed
    nexus = res(t, :nexus)
    wb_in_visible = res(t, :workbook, enclosing: nexus)
    assert RBAC.can?(who(t, :member), :edit, wb_in_visible)

    # the SAME workbook, but the enclosing nexus belongs to another tenant the member
    # can't view → the inner edit is denied even though role+grant would allow the leaf
    foreign_nexus = res("other", :nexus)
    wb_in_foreign = res(t, :workbook, grant: :draft, enclosing: foreign_nexus)
    refute RBAC.can?(who(t, :member), :edit, wb_in_foreign)

    # a cross-tenant draft grant on the leaf, enclosed by a nexus shared :read to me,
    # composes: I can VIEW the enclosing (grant :read) AND :edit the leaf (grant :draft)
    enclosing_shared = res("acme", :nexus, grant: :read)
    leaf_shared = res("acme", :workbook, grant: :draft, enclosing: enclosing_shared)
    assert RBAC.can?(who("beta", :member), :edit, leaf_shared)
  end

  test "a resource with no concrete tenant is denied (no grandfather auto-pass)" do
    t = "acme"
    # an owner gets nothing on a resource whose tenant is nil/absent — a decision
    # engine must not grandfather a missing owner into the caller's full role
    refute RBAC.can?(who(t, :owner), :view, %{level: :nexus, id: "x"})
    refute RBAC.can?(who(t, :owner), :view, %{tenant: nil, level: :nexus, id: "x"})
  end

  test "an over-deep enclosing chain hits the depth bound and denies (no unbounded recursion)" do
    t = "acme"
    # a normal 3-level chain (nexus ⊃ toolkit ⊃ workbook), all owner-viewable → allow
    shallow = Enum.reduce(1..3, nil, fn i, acc -> %{tenant: t, level: :workbook, id: "l#{i}", enclosing: acc} end)
    assert RBAC.can?(who(t, :owner), :edit, shallow)

    # a pathologically deep chain (>8) is denied by the @max_depth bound even though
    # every individual level would otherwise pass — defensive, terminates, no loop
    deep = Enum.reduce(1..20, nil, fn i, acc -> %{tenant: t, level: :workbook, id: "d#{i}", enclosing: acc} end)
    refute RBAC.can?(who(t, :owner), :edit, deep)
  end

  test "subject/2 resolves role from the registry, defaulting member (owner when user==tenant)" do
    t = uniq("org")
    # the tenant's self-identity (user == tenant) defaults to owner — dev/desktop floor
    assert RBAC.subject(t, t).role == :owner
    # an unknown member defaults to member
    assert RBAC.subject(t, "stranger").role == :member
    # an explicit role from the registry wins
    ControlPlane.set_role(t, "mara", "admin")
    assert RBAC.subject(t, "mara").role == :admin
    # a platform-admin row ("*") lights platform_admin?
    ControlPlane.set_role("*", "root", "admin")
    assert RBAC.subject(t, "root").platform_admin?
    refute RBAC.subject(t, "mara").platform_admin?
  end
end
