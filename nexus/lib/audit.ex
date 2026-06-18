defmodule Nexus.Audit do
  @moduledoc """
  The capability audit: a unit may only call host capabilities it explicitly **grants** in its
  header (`grant: [emit, now]`). `unit/1` returns the caps a unit *uses* but did not *grant* —
  the violations; `[]` means clean. The weave/build runs this so an author sees exactly which
  host reach a unit takes, and an ungranted cap is a hard error, not a silent capability.
  """

  @doc "Caps a unit imports without granting. `[]` = clean."
  def unit(node), do: Enum.reject(used(node), &(&1 in granted(node)))

  @doc """
  Audit a whole `.work` folder → `%{unit_name => [ungranted caps]}` for the units that violate.
  An empty map means the whole workbook is capability-clean.
  """
  def workbook(root) do
    (Path.wildcard(Path.join(root, "*.work")) ++ Path.wildcard(Path.join(root, "**/*.work")))
    |> Enum.uniq()
    |> Enum.flat_map(fn f -> f |> File.read!() |> Nexus.Literate.parse() |> Enum.filter(&(&1.type == :code)) end)
    |> Enum.map(fn u -> {u.name, unit(u)} end)
    |> Enum.reject(fn {_name, violations} -> violations == [] end)
    |> Map.new()
  end

  # Host fns the unit imports — `extern "C" { fn x }` (rust) / `extern T x(` (C/zig) — that are
  # known Dock caps. Exports (`pub fn`, `export fn`) get filtered out: they aren't host fns.
  defp used(%{body: body}) when is_binary(body) do
    host = Nexus.Capabilities.host_fn_names()

    (Regex.scan(~r/\bfn\s+([a-z_]\w*)\s*\(/, body) ++ Regex.scan(~r/\bextern\s+[a-z]\w*\s+([a-z_]\w*)\s*\(/, body))
    |> Enum.map(&List.last/1)
    |> Enum.uniq()
    |> Enum.filter(&(&1 in host))
  end

  defp used(_), do: []

  @doc "Cap names listed in the unit's `grant: [ … ]` header (string values dropped so they don't leak)."
  def granted(%{header: header}) when is_binary(header) do
    case Regex.run(~r/grant:?\s*\[([^\]]*)\]/, header, capture: :all_but_first) do
      [inner] -> inner |> String.replace(~r/"[^"]*"/, "") |> then(&Regex.scan(~r/[a-z_]\w+/, &1)) |> List.flatten()
      _ -> []
    end
  end

  def granted(_), do: []
end
