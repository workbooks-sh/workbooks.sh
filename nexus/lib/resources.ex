defmodule Nexus.Resources do
  @moduledoc """
  Enumerate the `resource` units declared across a deployed tree — the registry the cloud Data
  page reads to list "every table" for a tenant. There is no compile-time registry of resource
  modules; the source of truth is the `.work` tree, so we parse it (the same walk `Nexus.SSR`
  uses) and resolve each `resource` block to its struct module, declaring file, owning workspace,
  fields, and per-tenant row count.

  Scoped by tenant via `Nexus.Store.count/2` — never crosses the tenant partition.
  """

  @doc """
  Every resource under `root`, scoped to `tenant`. Each entry:

      %{name: "Session", module: Session, file: "studio/index.work",
        workspace: "studio", fields: [{:prompt, :text}, ...], count: 42}

  Resources whose blocks fail to compile are skipped (a malformed draft never breaks the listing).
  """
  def list(root \\ Nexus.Config.data_dir(), tenant \\ Nexus.Store.default_tenant()) do
    workspaces = Nexus.Config.workspaces() || []

    for {file, node} <- resource_nodes(root),
        mod = safe_compile(node),
        not is_nil(mod) do
      %{
        name: to_string(node.name),
        module: mod,
        file: file,
        workspace: workspace_of(file, workspaces),
        fields: safe_fields(node),
        count: safe_count(mod, tenant)
      }
    end
    # A resource name is a single global module, so two files declaring `resource Foo` are the SAME
    # backing table — collapse to one entry (don't show the same table twice). `files` keeps every
    # declaring path so a name clash is visible, not silently shadowed.
    |> Enum.group_by(& &1.name)
    |> Enum.map(fn {_name, [first | _] = entries} ->
      Map.put(first, :files, Enum.map(entries, & &1.file) |> Enum.uniq() |> Enum.sort())
    end)
    |> Enum.sort_by(&{&1.workspace || "", &1.name})
  end

  @doc "Resolve a resource by its declared name, scoped to a tenant — `{:ok, entry} | :error`."
  def fetch(name, root \\ Nexus.Config.data_dir(), tenant \\ Nexus.Store.default_tenant()) do
    name = to_string(name)

    case Enum.find(list(root, tenant), &(&1.name == name)) do
      nil -> :error
      entry -> {:ok, entry}
    end
  end

  # --- internals ---

  # Resources can be declared in ANY surface across the deploy (each workspace subtree is its own
  # mount), so — unlike `Nexus.SSR.files/1`, which stops at a single surface's boundary — we walk
  # the WHOLE tree. TEMPLATE.work is a CLI manifest, not content.
  defp resource_nodes(root) do
    Path.wildcard(Path.join(root, "**/*.work"))
    |> Enum.reject(&(Path.basename(&1) == "TEMPLATE.work"))
    |> Enum.sort()
    |> Enum.flat_map(fn file ->
      for node <- safe_parse(file),
          node.type == :code,
          node.kind == "resource" do
        {Path.relative_to(file, root), node}
      end
    end)
  end

  defp safe_parse(file) do
    Nexus.Literate.parse(File.read!(file))
  rescue
    _ -> []
  end

  # The owning workspace = the longest declared workspace id that prefixes the file's path.
  defp workspace_of(file, workspaces) do
    workspaces
    |> Enum.map(& &1.id)
    |> Enum.filter(fn id -> file == id or String.starts_with?(file, id <> "/") end)
    |> Enum.max_by(&String.length/1, fn -> nil end)
  end

  defp safe_compile(node) do
    Nexus.Resource.compile(node)
  rescue
    _ -> nil
  end

  defp safe_fields(node) do
    Nexus.Resource.fields(node)
  rescue
    _ -> []
  end

  defp safe_count(mod, tenant) do
    Nexus.Store.count(mod, tenant)
  rescue
    _ -> 0
  end
end
