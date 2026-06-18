defmodule WorkCore.Artifact do
  @moduledoc """
  §3 — the artifact facet: what a compiled `.wasm` component *actually* imports and
  exports, read back from the binary, versus what the source *declared* (§2). The
  graph (§9) carries the declared interface; this closes the loop by reading the
  built component's real WIT and diffing it — so "what we said" and "what we shipped"
  are checked against each other instead of assumed equal.
  """

  @doc """
  Read a compiled component's WIT world via `wasm-tools component wit <path>`.
  Returns `{:ok, wit_text}` or `{:error, message}`.
  """
  def read_wit(component_path) do
    System.cmd("wasm-tools", ["component", "wit", component_path], stderr_to_stdout: true)
    |> case do
      {wit, 0} -> {:ok, wit}
      {msg, _} -> {:error, msg}
    end
  rescue
    e in ErlangError -> {:error, "wasm-tools unavailable: #{inspect(e)}"}
  end

  @doc "Parse the import/export identifier sets out of WIT source. `%{imports: [..], exports: [..]}`."
  def interface(wit_text) when is_binary(wit_text) do
    %{
      exports: scan(~r/export\s+([a-z0-9%-]+)/, wit_text),
      imports: scan(~r/import\s+([a-z0-9%-]+)/, wit_text)
    }
  end

  defp scan(re, text), do: Regex.scan(re, text) |> Enum.map(&List.last/1) |> Enum.uniq()

  @doc """
  Read a component and return its artifact facet: `%{wit, imports, exports}` (or
  `{:error, _}`). This is what populates a graph node's `facets.artifact`.
  """
  def facet(component_path) do
    with {:ok, wit} <- read_wit(component_path) do
      iface = interface(wit)
      {:ok, Map.put(iface, :wit, wit)}
    end
  end

  @doc """
  Attach the artifact facet to a graph node from its compiled component path.
  Leaves the node untouched (artifact stays nil) if the component can't be read.
  """
  def annotate_node(%{facets: facets} = node, component_path) do
    case facet(component_path) do
      {:ok, artifact} -> %{node | facets: %{facets | artifact: artifact}}
      {:error, _} -> node
    end
  end

  @doc """
  Diff declared interface (§2 WIT) against the compiled component's actual WIT.
  `%{missing_exports, extra_exports, missing_imports, extra_imports, ok?}` where
  *missing* = declared but absent from the binary, *extra* = present in the binary
  but undeclared. `ok?` is true when neither side drifted.
  """
  def diff(declared_wit, actual_wit) when is_binary(declared_wit) and is_binary(actual_wit) do
    d = interface(declared_wit)
    a = interface(actual_wit)

    res = %{
      missing_exports: d.exports -- a.exports,
      extra_exports: a.exports -- d.exports,
      missing_imports: d.imports -- a.imports,
      extra_imports: a.imports -- d.imports
    }

    Map.put(res, :ok?, Enum.all?(Map.values(res), &(&1 == [])))
  end
end
