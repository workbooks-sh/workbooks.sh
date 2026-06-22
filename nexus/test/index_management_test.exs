defmodule Nexus.IndexManagementTest do
  use ExUnit.Case, async: true
  alias Nexus.{Index, Autopoet.Eval}

  setup do
    root = Path.join(System.tmp_dir!(), "nexus_im_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "site"))
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  test "management parses from an index, defaults managed", %{root: root} do
    File.write!(Path.join(root, "index.work"), "deploy do\n  tiers=\"x\"\nend\n")
    File.write!(Path.join(root, "site/index.work"), "management frozen\n")
    assert Index.management(Path.join(root, "index.work")) == "managed"
    assert Index.management(Path.join(root, "site/index.work")) == "frozen"
  end

  test "effective management is the most restrictive ancestor", %{root: root} do
    File.write!(Path.join(root, "index.work"), "management proposed\n")
    File.write!(Path.join(root, "site/index.work"), "# no posture here\n")
    # ancestor (root) is proposed, sub is managed -> effective = proposed
    assert Index.effective_management(root, Path.join(root, "site")) == "proposed"
  end

  test "a frozen subtree blocks even a benign app edit (eval routes human)", %{root: root} do
    File.write!(Path.join(root, "index.work"), "deploy do\n  tiers=\"x\"\nend\n")
    File.write!(Path.join(root, "site/index.work"), "management frozen\n")
    File.write!(Path.join(root, "site/page.work"), "# the page\n")

    r = Eval.validate(root, %{"site/page.work" => "# the page, reworded\n"})
    assert r.autonomy == :human_gated
    assert {:subtree_management, "frozen"} in r.reasons
  end

  test "a managed subtree lets an app edit flow autonomously", %{root: root} do
    File.write!(Path.join(root, "index.work"), "deploy do\n  tiers=\"x\"\nend\n")
    File.write!(Path.join(root, "site/page.work"), "# the page\n")

    r = Eval.validate(root, %{"site/page.work" => "# improved page\n"})
    assert r.autonomy == :autonomous
  end
end
