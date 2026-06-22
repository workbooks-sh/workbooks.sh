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

  test "a single index ceiling parses its grants; absent block = :unbounded", %{dir: dir} do
    bounded = write(dir, "a/index.work", "ceiling do\n  grant net, llm, vfs\nend\n")
    open = write(dir, "b/index.work", "# no ceiling here\ndeploy do\n  tiers=\"x\"\nend\n")

    assert Index.ceiling(bounded) == ["llm", "net", "vfs"]
    assert Index.ceiling(open) == :unbounded
  end

  test "effective ceiling is the intersection of ancestors; deeper can only narrow", %{dir: dir} do
    write(dir, "index.work", "ceiling do\n  grant net, llm, vfs\nend\n")
    write(dir, "sub/index.work", "ceiling do\n  grant net, llm\nend\n")
    leaf = write(dir, "sub/leaf/index.work", "ceiling do\n  grant net\nend\n")

    # root [net,llm,vfs] ∩ sub [net,llm] ∩ leaf [net] = [net]
    assert Index.effective_ceiling(dir, leaf) == ["net"]
    # at the sub level: root ∩ sub = [net,llm]
    assert Index.effective_ceiling(dir, Path.join(dir, "sub")) == ["llm", "net"]
  end

  test "a deeper index CANNOT widen past an ancestor (intersection clamps it)", %{dir: dir} do
    write(dir, "index.work", "ceiling do\n  grant net\nend\n")
    # the child tries to grant itself llm + secrets on top of net — must be dropped
    child = write(dir, "child/index.work", "ceiling do\n  grant net, llm, secrets\nend\n")

    assert Index.effective_ceiling(dir, child) == ["net"]
  end

  test "clamp_grant intersects a declared grant with the effective ceiling", %{dir: dir} do
    write(dir, "index.work", "ceiling do\n  grant net, llm\nend\n")
    agent_dir = Path.join(dir, "agents")
    File.mkdir_p!(agent_dir)

    # an agent declaring [net, llm, secrets] under this ceiling keeps only [net, llm]
    assert Index.clamp_grant(["net", "llm", "secrets"], dir, agent_dir) == ["net", "llm"]
    # no ceiling anywhere → declared passes untouched
    assert Index.clamp_grant(["net", "secrets"], Path.join(dir, "elsewhere"), agent_dir) == [
             "net",
             "secrets"
           ]
  end
end
