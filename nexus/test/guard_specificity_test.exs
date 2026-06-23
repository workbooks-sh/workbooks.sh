defmodule Nexus.Auth.GuardSpecificityTest do
  @moduledoc "Seam 1.3 / wb-ma9v: most-specific-wins across public/protect (no public-shadows-protect)."
  use ExUnit.Case, async: false
  alias Nexus.Auth.Guard

  setup do
    Guard.reset()
    on_exit(&Guard.reset/0)
    :ok
  end

  test "a narrow protect beats a broad public (no shadowing)" do
    Guard.public(["/api/**"])
    Guard.protect("POST /api/admin/**", role: "admin")

    anon = %{tenant: "t", roles: [], user: nil}
    member = %{tenant: "t", roles: ["member"], user: "u"}
    admin = %{tenant: "t", roles: ["admin"], user: "u"}

    # the broad public still covers general /api
    assert Guard.decide("GET", "/api/things", anon) == :allow
    # but the narrow protect wins for the admin subpath — NOT shadowed by public
    assert Guard.decide("POST", "/api/admin/wipe", member) == :forbidden
    assert Guard.decide("POST", "/api/admin/wipe", admin) == :allow
  end

  test "equal specificity: protect wins the tie (fail-safe)" do
    Guard.public(["/x/:id"])
    Guard.protect("/x/:id", role: "admin")
    member = %{tenant: "t", roles: ["member"], user: "u"}
    assert Guard.decide("GET", "/x/1", member) == :forbidden
  end
end
