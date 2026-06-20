defmodule Nexus.DeployTreeTest do
  use ExUnit.Case, async: true

  # deploy-as-index-tree: a `deploy` block is only valid in an index.work, one per index.

  defp tree(files) do
    root = Path.join(System.tmp_dir!(), "wbdt_#{System.unique_integer([:positive])}")
    for {path, body} <- files do
      full = Path.join(root, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, body)
    end
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  @deploy "deploy do\n  search=\"brave\"\nend\n"

  test "a single root index.work with one deploy block is valid + is the one node" do
    root = tree(%{"index.work" => "# Manifest\n\n" <> @deploy, "cloud/index.work" => "# Cloud\n"})
    assert :ok == Nexus.Deploy.validate(root)
    assert [node] = Nexus.Deploy.nodes(root)
    assert Path.basename(node) == "index.work"
    assert Path.dirname(node) == root
  end

  test "a deploy block in a NON-index file is drift → error" do
    root = tree(%{"index.work" => "# Manifest\n", "stray.work" => "# Stray\n\n" <> @deploy})
    assert {:error, [msg]} = Nexus.Deploy.validate(root)
    assert msg =~ "stray.work"
    assert msg =~ "only takes effect in index.work"
  end

  test "two deploy blocks in one index → error" do
    root = tree(%{"index.work" => "# Manifest\n\n" <> @deploy <> "\n" <> @deploy})
    assert {:error, [msg]} = Nexus.Deploy.validate(root)
    assert msg =~ "exactly one deploy block per index"
  end

  test "nested indexes each with a deploy block are sub-deployments (not drift), shallowest first" do
    root =
      tree(%{
        "index.work" => "# Root\n\n" <> @deploy,
        "app/index.work" => "# App\n\n" <> @deploy,
        "marketing/index.work" => "# Mktg\n\n" <> @deploy
      })

    assert :ok == Nexus.Deploy.validate(root)
    nodes = Nexus.Deploy.nodes(root)
    assert length(nodes) == 3
    # the root manifest sorts first (shallowest)
    assert Path.dirname(hd(nodes)) == root
  end

  test "our real dogfood tree obeys the rules" do
    assert :ok == Nexus.Deploy.validate(Path.expand("../../dogfood", __DIR__))
  end
end
