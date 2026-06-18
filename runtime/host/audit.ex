defmodule Workbooks.Audit do
  @moduledoc """
  §9 weave-gate audits beyond reference resolution. `caps/1` is the `:audit_caps`
  gate: a unit that *uses* a Dock capability (a `Dock.fetch`/`Dock.secret`/… call in
  its body) must *grant* it in its header. An ungranted use is a capability leak the
  weave refuses. Pure over the parse + the Elixir AST calls.
  """

  alias Workbooks.{Literate, Wit, Extract}

  # the Dock function a unit calls → the sandbox-enforced capability it requires.
  # (agent/complete/browse are nexus-tier services, not per-unit sandbox caps, so
  # they aren't gated here.)
  @dock_caps %{
    fetch: "net",
    get: "net",
    post: "net",
    secret: "secrets",
    secrets: "secrets",
    kv: "kv",
    put: "kv",
    read: "kv",
    exec: "exec",
    run: "exec"
  }

  @doc "Find units that use a Dock capability they did not grant. Returns [%{unit, cap}]."
  def caps(dir) do
    dir
    |> units()
    |> Enum.flat_map(fn node ->
      granted = node |> Wit.grants() |> MapSet.new()

      node
      |> used_caps()
      |> Enum.reject(&granted?(&1, granted))
      |> Enum.map(&%{unit: node.name, cap: &1})
    end)
  end

  # the Dock capabilities a unit's body exercises
  def used_caps(node) do
    node
    |> Extract.facts()
    |> Map.fetch!(:calls)
    |> Enum.flat_map(fn {mod, fun, _arity} ->
      if dock?(mod), do: [@dock_caps[fun]], else: []
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp dock?(mod), do: mod |> Module.split() |> List.last() == "Dock"

  # a cap is satisfied by its own grant; secrets are stored in kv, so a kv grant
  # also covers a `secrets` use (the demo's `kv: :secrets` pattern).
  defp granted?("secrets", granted), do: MapSet.member?(granted, "secrets") or MapSet.member?(granted, "kv")
  defp granted?(cap, granted), do: MapSet.member?(granted, cap)

  defp units(dir) do
    (Path.wildcard(Path.join(dir, "*.work")) ++ Path.wildcard(Path.join(dir, "**/*.work")))
    |> Enum.uniq()
    |> Enum.flat_map(fn path -> Literate.parse(File.read!(path)) end)
    |> Enum.filter(fn n -> n.type == :code and n.name end)
  end
end
