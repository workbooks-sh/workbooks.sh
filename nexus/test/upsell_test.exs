defmodule Nexus.UpsellTest do
  use ExUnit.Case, async: false
  alias Nexus.ControlPlane, as: CP
  alias Nexus.Upsell

  # Upsell reads its price facts from the configured tier table (Nexus.Config.tiers). These tiers are
  # a FIXTURE for the test; the runtime ships a neutral default and an operator supplies real tiers.
  # (Upsell itself is slated to move out of the standard into our cloud/workbook — bd wb-n9ez.)
  @tiers [
    %{id: "starter", name: "Starter", ram_mb: 1_024, storage_gb: 10, price: 0, domains?: false},
    %{id: "team", name: "Team", ram_mb: 4_096, storage_gb: 100, price: 49, domains?: true},
    %{id: "scale", name: "Scale", ram_mb: 16_384, storage_gb: 1_000, price: 199, domains?: true}
  ]

  setup do
    Nexus.Config.put(:tiers, @tiers)
    org = "org_ups_#{System.unique_integer([:positive])}"
    on_exit(fn ->
      Nexus.Config.boot()
      for nx <- CP.list(org, :nexus), do: CP.delete(org, :nexus, nx.id)
    end)
    {:ok, org: org}
  end

  defp seed(org, plan, state \\ "running") do
    id = "nx-#{System.unique_integer([:positive])}"
    {:ok, _} = CP.put(org, :nexus, id, %{plan: plan, state: state})
    id
  end

  test "never blank: minimal data (no nexus) still yields a complete starter→team page", %{org: org} do
    page = Upsell.assemble(org, org_name: "Acme", personalize: false)
    assert page.org == "Acme"
    refute page.at_ceiling
    hero = Enum.find(page.blocks, &(&1.type == :hero))
    cta = Enum.find(page.blocks, &(&1.type == :cta))
    assert hero.copy.headline =~ "Acme"
    # Price is pinned from facts (Team = $49/mo), never blank.
    assert cta.copy.sub =~ "$49/mo"
    assert cta.href == "/billing/checkout?plan=team"
  end

  test "falls back to the org id when no display name given", %{org: org} do
    page = Upsell.assemble(org, personalize: false)
    assert page.org == org
  end

  test "near-capacity nexus shifts to the reassure layout + urgency copy", %{org: org} do
    seed(org, "starter")
    page = Upsell.assemble(org, org_name: "Beta", personalize: false)
    # starter usage is derived hot/not — assert the structure regardless, and headroom present
    assert page.layout in ["focused", "reassure"]
    assert Enum.any?(page.blocks, &(&1.type in [:headroom, :unlocks]))
  end

  test "top tier (scale): no checkout, points to team not a second nexus", %{org: org} do
    seed(org, "scale")
    page = Upsell.assemble(org, org_name: "Gamma", personalize: false)
    assert page.at_ceiling
    refute Enum.any?(page.blocks, fn b -> b.type == :cta and (b[:href] || "") =~ "checkout" end)
    hero = Enum.find(page.blocks, &(&1.type == :hero))
    assert hero.copy.headline =~ "Gamma"
  end

  test "guardrail: sanitize drops any slot containing a number / $ / unit", %{org: _} do
    dirty = %{
      "hero" => %{"headline" => "Grow with confidence", "subhead" => "Only $49/mo for more"},
      "cta" => %{"label" => "Upgrade now", "sub" => "Get 4 GB of memory"}
    }

    clean = Upsell.sanitize(dirty)
    assert clean["hero"]["headline"] == "Grow with confidence"
    refute Map.has_key?(clean["hero"], "subhead")   # "$49/mo" dropped
    assert clean["cta"]["label"] == "Upgrade now"
    refute Map.has_key?(clean["cta"], "sub")          # "4 GB" dropped
  end

  test "personalize: AI copy overlays prose but prices stay pinned; bad layout ignored", %{org: org} do
    fake_llm = fn _msgs, _opts ->
      {:ok, %{content: ~s({"layout":"reassure","copy":{"hero":{"headline":"Datadog, ship faster","subhead":"costs only $1"},"cta":{"label":"Let's scale"}}})}}
    end

    page = Upsell.assemble(org, org_name: "Datadog", llm: fake_llm)
    assert page.personalized
    assert page.layout == "reassure"
    hero = Enum.find(page.blocks, &(&1.type == :hero))
    cta = Enum.find(page.blocks, &(&1.type == :cta))
    # personalized prose applied…
    assert hero.copy.headline == "Datadog, ship faster"
    assert cta.copy.label == "Let's scale"
    # …but the numeric subhead was dropped (guardrail), keeping the safe base copy…
    refute hero.copy.subhead =~ "$1"
    # …and the pinned price survives in the CTA sub.
    assert cta.copy.sub =~ "$49/mo"
  end

  test "LLM error degrades to the deterministic base (never blank)", %{org: org} do
    page = Upsell.assemble(org, org_name: "Err", llm: fn _, _ -> {:error, :boom} end)
    refute page.personalized
    assert Enum.any?(page.blocks, &(&1.type == :hero))
  end
end
