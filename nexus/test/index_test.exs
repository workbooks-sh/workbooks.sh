defmodule Nexus.IndexTest do
  use ExUnit.Case, async: true

  alias Nexus.Index

  setup do
    dir = Path.join(System.tmp_dir!(), "nexus_index_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp write(dir, rel, body) do
    path = Path.join(dir, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
    path
  end

  test "a config/composition index is pure", %{dir: dir} do
    path =
      write(dir, "index.work", """
      # A clean surface

      deploy do
        tiers="solo | Solo | 512 10 12 no"
      end

      ceiling do
        grant net, llm, vfs
      end
      """)

    assert Index.purity(path) == []
  end

  test "an index with a server logic block is impure", %{dir: dir} do
    path =
      write(dir, "index.work", """
      # A surface that smuggled in logic

      resource Todo do
        field :title, :string
      end

      server :cloud do
        route "GET /x", :handler
        def handler(_req), do: "ok"
      end
      """)

    violations = Index.purity(path)
    assert {"server", "cloud"} in violations
    # the declaration is fine — only the logic unit is flagged
    refute Enum.any?(violations, fn {k, _} -> k == "resource" end)
  end

  test "a client island in an index is flagged", %{dir: dir} do
    path =
      write(dir, "index.work", """
      client :app do
        <div>the whole SPA</div>
      end
      """)

    assert {"client", "app"} in Index.purity(path)
  end

  test "purity_tree reports only the impure indexes under a root", %{dir: dir} do
    write(dir, "index.work", "deploy do\n  tiers=\"x\"\nend\n")
    write(dir, "clean/index.work", "# just prose, references [[children]]\n")
    write(dir, "dirty/index.work", "server :api do\n  def f(_), do: 1\nend\n")

    tree = Index.purity_tree(dir)
    assert Map.has_key?(tree, "dirty/index.work")
    assert tree["dirty/index.work"] == [{"server", "api"}]
    refute Map.has_key?(tree, "index.work")
    refute Map.has_key?(tree, "clean/index.work")
  end
end
