defmodule Nexus.FacetTest do
  @moduledoc """
  wb-jr1py.9: the workbook facet — `facet kit|app|agent` in a surface's index.work. Source read,
  dir read, tree audit (manifest exempt, lone-root = the surface), staged warnings in Compile.check,
  and the literate parser treating `facet` as a first-class declaration.
  """
  use ExUnit.Case, async: true

  alias Nexus.Facet

  test "facet_source reads the declaration; nil when absent or malformed" do
    assert Facet.facet_source("# T\n\nfacet app\n") == "app"
    assert Facet.facet_source("# T\n\n  facet kit\n") == "kit"
    assert Facet.facet_source("# T\nfacet agent\nprose") == "agent"
    assert Facet.facet_source("# T\nno facet here\n") == nil
    assert Facet.facet_source("facet container\n") == nil
    assert Facet.facet_source(nil) == nil
  end

  test "the unit-kind blocks do NOT read as a workbook facet" do
    # `app :name do` / `agent :x do` are BLOCK kinds — distinct from the facet declaration.
    assert Facet.facet_source("# T\n\napp :shell do\n  view\nend\n") == nil
    assert Facet.facet_source("# T\n\nagent :researcher do\nend\n") == nil
  end

  defp tmpdir do
    d = Path.join(System.tmp_dir!(), "facet-#{System.unique_integer([:positive])}")
    File.mkdir_p!(d)
    on_exit(fn -> File.rm_rf!(d) end)
    d
  end

  test "validate: manifest root exempt; each nested surface must declare; names the offender" do
    root = tmpdir()
    File.write!(Path.join(root, "index.work"), "# Manifest\n\ndeploy do\nend\n")
    File.mkdir_p!(Path.join(root, "good"))
    File.write!(Path.join(root, "good/index.work"), "# Good\n\nfacet app\n")
    File.mkdir_p!(Path.join(root, "bad"))
    File.write!(Path.join(root, "bad/index.work"), "# Bad — no facet\n")

    assert {:error, [msg]} = Facet.validate(root)
    assert msg =~ "bad/index.work"
    assert msg =~ "facet kit|app|agent"
  end

  test "validate: a lone root index.work IS the surface (pushed single workbook)" do
    root = tmpdir()
    File.write!(Path.join(root, "index.work"), "# Lone\n")
    assert {:error, [msg]} = Facet.validate(root)
    assert msg =~ "./index.work"

    File.write!(Path.join(root, "index.work"), "# Lone\n\nfacet agent\n")
    assert :ok = Facet.validate(root)
  end

  test "validate: no index.work anywhere → nothing to audit" do
    root = tmpdir()
    File.write!(Path.join(root, "notes.work"), "# Just notes\n")
    assert :ok = Facet.validate(root)
  end

  test "facet/1 reads a surface dir" do
    root = tmpdir()
    File.write!(Path.join(root, "index.work"), "# S\n\nfacet kit\n")
    assert Facet.facet(root) == "kit"
    assert Facet.facet(Path.join(root, "missing")) == nil
  end

  test "Compile.check carries the missing facet as a WARNING, never an error (staged enforcement)" do
    root = tmpdir()
    File.write!(Path.join(root, "index.work"), "# Lone surface, no facet\n")

    r = Nexus.Compile.check(root)
    assert r.ok?, "a missing facet must not fail the gate during the staged window"
    assert [%{kind: "facet", reason: reason}] = r.warnings
    assert reason =~ "declares no facet"
  end

  test "the literate parser treats `facet app` as a declaration node" do
    nodes = Nexus.Literate.parse("# T\n\nfacet app\n")
    assert Enum.any?(nodes, fn n -> n.type == :decl and String.starts_with?(n.text, "facet") end)
  end

  # ── ownership (wb-jr1py.10) ────────────────────────────────────────────────────────────────────

  test "agent def_from_unit captures + normalizes `manages` (string / atom / bare identifier)" do
    src = """
    agent :keeper do
      prompt "you keep the shop"
      manages "site/shop", :home
      management managed
    end
    """

    [unit] = Nexus.Literate.parse(src) |> Enum.filter(&(&1.type == :code and &1.kind == "agent"))
    d = Nexus.Agent.def_from_unit(unit)
    assert d[:manages] == ["site/shop", "home"]
    assert d[:management] == "managed"
  end

  test "owners/owner resolve the binding; audit enforces exists + facet app + single owner" do
    root = tmpdir()
    File.write!(Path.join(root, "index.work"), "# Manifest\n\ndeploy do\nend\n")
    File.mkdir_p!(Path.join(root, "shop"))
    File.write!(Path.join(root, "shop/index.work"), "# Shop\n\nfacet app\n")
    File.mkdir_p!(Path.join(root, "corpus"))
    File.write!(Path.join(root, "corpus/index.work"), "# Corpus\n\nfacet kit\n")

    File.write!(Path.join(root, "agents.work"), """
    # Agents

    agent :keeper do
      prompt "runs the shop"
      manages "shop"
    end
    """)

    assert :ok = Facet.validate(root)
    assert %{agent: "keeper"} = Facet.owner(root, "shop")
    assert Facet.owner(root, "corpus") == nil

    # unknown target + kit target + duplicate claim all flagged
    File.write!(Path.join(root, "agents.work"), """
    # Agents

    agent :keeper do
      manages "shop", "ghost", "corpus"
    end

    agent :rival do
      manages "shop"
    end
    """)

    assert {:error, msgs} = Facet.validate(root)
    joined = Enum.join(msgs, "\n")
    assert joined =~ ~s(manages "ghost" — no such surface)
    assert joined =~ ~s(its facet is `kit`)
    assert joined =~ ~s("shop" has 2 managing agents)
  end

  test "first-party surfaces are migrated (repo dogfood tree is clean)" do
    # Guards the migration: our own deploy tree must audit clean, or CI content pushes would warn forever.
    root = Path.expand("../../dogfood", __DIR__)

    if File.dir?(root) do
      assert :ok = Facet.validate(root)
    end
  end
end
