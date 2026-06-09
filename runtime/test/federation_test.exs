defmodule Workbooks.FederationTest do
  @moduledoc """
  wb-39j.1 — the federation core: register a data-source plugin, route
  SELECT … FROM <entity> to it (else fall through to the VFS), and discover plugins
  from their manifests (skipping fixtures whose #+IMPL doesn't exist).
  """
  use ExUnit.Case, async: false

  alias Workbooks.{DataSource, Federation}

  # A reference data-source plugin (the shape Linear/Asana specialize).
  defmodule DemoSource do
    @behaviour Workbooks.DataSource
    @impl true
    def query("demo-item", %{sql: sql}, _opts) do
      {:ok, [%{"id" => 1, "title" => "alpha", "echo" => sql}, %{"id" => 2, "title" => "beta"}]}
    end

    def query(_entity, _q, _opts), do: {:ok, []}
  end

  test "register + route FROM <entity> to the plugin, else :not_federated" do
    DataSource.register("demo-item", DemoSource)
    assert DataSource.lookup("demo-item") == DemoSource

    assert {:ok, rows} = Federation.query("SELECT * FROM demo-item WHERE x = 1")
    assert length(rows) == 2
    assert hd(rows)["title"] == "alpha"
    assert hd(rows)["echo"] =~ "demo-item"

    # an unregistered entity is NOT federated → caller falls through to the VFS.
    assert :not_federated = Federation.query("SELECT * FROM workspace_files")
    assert Federation.federated?("SELECT * FROM demo-item")
    refute Federation.federated?("SELECT * FROM workspace_files")
  end

  test "discover registers a data-source plugin from its manifest; stale #+IMPL is skipped" do
    root = Path.join(System.tmp_dir!(), "wb-fed-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join([root, "demo", "plugin"]))

    File.write!(Path.join([root, "demo", "plugin", "manifest.org"]), """
    #+TITLE: demo
    #+SLOT: data-source
    #+ENTITIES: demo-thing
    #+IMPL: Workbooks.FederationTest.DemoSource
    """)

    registered = Federation.discover(root)
    assert {"demo-thing", DemoSource} in registered
    assert DataSource.lookup("demo-thing") == DemoSource

    # A fixture naming a non-existent #+IMPL (the linear/asana old-mainline case) is
    # SKIPPED gracefully, not an error.
    File.mkdir_p!(Path.join([root, "bogus", "plugin"]))

    File.write!(Path.join([root, "bogus", "plugin", "manifest.org"]), """
    #+SLOT: data-source
    #+ENTITIES: nope
    #+IMPL: WorkbooksRuntime.Plugin.DoesNotExist
    """)

    assert Enum.all?(Federation.discover(root), fn {e, _} -> e != "nope" end)
    refute DataSource.lookup("nope")
  end

  test "Library.query routes a federated FROM to the plugin (end to end)" do
    DataSource.register("demo-item", DemoSource)
    result = Workbooks.Library.query("dev", "SELECT * FROM demo-item")

    assert result[:federated] == true
    assert [%{member: "federation", rows: rows}] = result.rows
    assert length(rows) == 2
  end
end
