defmodule Nexus.ResourceAshLiveTest do
  use ExUnit.Case, async: false

  defp lead do
    "resource Lead do\n  name :text\n  revenue :int\n  status :new | :won\nend\n"
    |> Nexus.Literate.parse()
    |> Enum.find(&(&1.type == :code))
  end

  test "a resource materializes into a live Ash resource with working CRUD" do
    {res, domain} = Nexus.Resource.Ash.materialize(lead())

    {:ok, a} =
      res
      |> Ash.Changeset.for_create(:create, %{name: "Acme", revenue: 100, status: :new})
      |> Ash.create(domain: domain)

    assert a.name == "Acme"
    assert a.revenue == 100

    {:ok, all} = Ash.read(res, domain: domain)
    assert length(all) == 1
  end

  test "the inline enum becomes a real constraint — invalid values are rejected" do
    {res, domain} = Nexus.Resource.Ash.materialize(lead())

    assert {:error, _} =
             res
             |> Ash.Changeset.for_create(:create, %{name: "X", status: :bogus})
             |> Ash.create(domain: domain)
  end
end
