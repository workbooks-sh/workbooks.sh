defmodule Workbooks.Resource.AshLiveTest do
  use ExUnit.Case, async: false
  alias WorkCore.Literate
  alias Workbooks.Resource

  defp build(src) do
    node = Literate.parse(src) |> Enum.find(&(&1.type == :code))
    {mod, _domain} = Resource.Ash.materialize(node)
    Application.ensure_all_started(:ash)
    mod
  end

  defp create!(mod, attrs), do: mod |> Ash.Changeset.for_create(:create, attrs) |> Ash.create!()

  test "a resource with diverse data types compiles to a live DB and round-trips every type" do
    acct =
      build("""
      resource Account do
        name     :text
        balance  :int
        rate     :float
        active   :bool
        tier     :free | :pro | :enterprise
        tags     [:text]
      end
      """)

    row = create!(acct, %{name: "Acme", balance: 1000, rate: 1.5, active: true, tier: :pro, tags: ["x", "y"]})

    assert row.name == "Acme"          # :text  → string
    assert row.balance == 1000         # :int   → integer
    assert row.rate == 1.5             # :float → float
    assert row.active == true          # :bool  → boolean
    assert row.tier == :pro            # enum   → atom (validated)
    assert row.tags == ["x", "y"]      # [:text]→ list<string>

    assert length(Ash.read!(acct)) == 1
  end

  test "an inline-enum field is validated by the DB (bad value rejected)" do
    acct = build("resource Acct2 do\n  name :text\n  tier :free | :pro\nend\n")

    assert {:ok, _} = acct |> Ash.Changeset.for_create(:create, %{name: "ok", tier: :pro}) |> Ash.create()
    assert {:error, _} = acct |> Ash.Changeset.for_create(:create, %{name: "bad", tier: :enterprise}) |> Ash.create()
  end

  test "a named query becomes a filtered read action" do
    acct =
      build("""
      resource Acct3 do
        name :text
        tier :free | :pro
        query :pros, where: tier == :pro
      end
      """)

    create!(acct, %{name: "freebie", tier: :free})
    create!(acct, %{name: "payer", tier: :pro})

    pros = Ash.read!(acct, action: :pros)
    assert length(pros) == 1
    assert hd(pros).name == "payer"
  end
end
