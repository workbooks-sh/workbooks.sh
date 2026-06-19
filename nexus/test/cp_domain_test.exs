defmodule Nexus.ControlPlane.DomainTest do
  use ExUnit.Case, async: false
  alias Nexus.ControlPlane, as: CP
  alias Nexus.ControlPlane.Domain

  defmodule FakeFly do
    def add_certificate(_app, host, _opts),
      do: {:ok, %{"data" => %{"addCertificate" => %{"certificate" => %{"dnsValidationTarget" => "#{host}.fly.dev", "dnsValidationHostname" => "_acme.#{host}"}}}}}

    def remove_certificate(_app, _host, _opts), do: {:ok, %{}}
  end

  # The tier table is operator config (Nexus.Config.tiers); the runtime ships a neutral default. This
  # test configures a tier set with a domain gate (starter locked, team+ allowed) to exercise it.
  @tiers [
    %{id: "starter", name: "Starter", ram_mb: 1_024, storage_gb: 10, price: 0, domains?: false},
    %{id: "team", name: "Team", ram_mb: 4_096, storage_gb: 100, price: 49, domains?: true},
    %{id: "scale", name: "Scale", ram_mb: 16_384, storage_gb: 1_000, price: 199, domains?: true}
  ]

  setup do
    Nexus.Config.put(:tiers, @tiers)
    org = "org_dom_#{System.unique_integer([:positive])}"
    on_exit(fn ->
      Nexus.Config.boot()
      for d <- Domain.list(org), do: CP.delete(org, :domain, d.id)
      for nx <- CP.list(org, :nexus), do: CP.delete(org, :nexus, nx.id)
    end)
    {:ok, org: org}
  end

  defp seed_nexus(org, plan) do
    id = "nx-#{System.unique_integer([:positive])}"
    {:ok, _} = CP.put(org, :nexus, id, %{plan: plan, fly_app: "nexus-#{id}", state: "running"})
    id
  end

  test "starter tier cannot bind a custom domain", %{org: org} do
    seed_nexus(org, "starter")
    assert {:error, :tier_locked} = Domain.add(org, "apps.acme.com")
  end

  test "no nexus → cannot bind", %{org: org} do
    assert {:error, :no_nexus} = Domain.add(org, "apps.acme.com")
  end

  test "reserved + malformed hosts rejected", %{org: org} do
    seed_nexus(org, "team")
    assert {:error, :reserved_host} = Domain.add(org, "x.workbooks.sh")
    assert {:error, :invalid_host} = Domain.add(org, "not a domain")
  end

  test "team tier: add → pending with TXT challenge + CNAME target", %{org: org} do
    seed_nexus(org, "team")
    assert {:ok, v} = Domain.add(org, "Apps.ACME.com/path")
    assert v.host == "apps.acme.com"
    assert v.status == "pending"
    assert v.verify.type == "TXT"
    assert v.verify.name == "_workbooks-challenge.apps.acme.com"
    assert String.starts_with?(v.verify.value, "wb-verify=")
    assert String.ends_with?(v.cname.target, ".fly.dev")
  end

  test "a host is globally unique across orgs", %{org: org} do
    seed_nexus(org, "team")
    assert {:ok, _} = Domain.add(org, "shared.example.com")

    other = "org_other_#{System.unique_integer([:positive])}"
    seed_nexus(other, "team")
    assert {:error, :host_taken} = Domain.add(other, "shared.example.com")
    on_exit(fn -> for d <- Domain.list(other), do: CP.delete(other, :domain, d.id) end)
  end

  test "verify: matching TXT activates + requests the cert; wrong TXT fails", %{org: org} do
    seed_nexus(org, "team")
    {:ok, v} = Domain.add(org, "apps.acme.com")
    token = v.verify.value

    assert {:error, :txt_not_found} =
             Domain.verify(org, v.id, resolver: fn _ -> ["wb-verify=wrong"] end, fly: FakeFly)

    assert {:ok, active} =
             Domain.verify(org, v.id, resolver: fn _ -> [token] end, fly: FakeFly)

    assert active.status == "active"
    assert active.verified_at
    assert active.dns_validation.target == "apps.acme.com.fly.dev"
  end
end
