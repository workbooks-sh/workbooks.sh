defmodule Nexus.Graph.Render do
  @moduledoc """
  Dogfood: the unified graph (§9) rendered as a workbook — a plain HTML page built
  from `work-*` elements, the same primitives any workbook uses. The graph that
  maps the system is itself a workbook you can open. Composition-as-source: the
  elements ARE the data (NO JSON), units and edges are DOM nesting and attributes.
  """

  alias Nexus.Graph

  @doc "Render a graph as a self-contained workbook HTML string."
  def to_html(%Graph{} = g, opts \\ []) do
    title = Keyword.get(opts, :title, "System graph")
    units = Graph.units(g) |> Enum.sort_by(& &1.id)

    """
    <!doctype html>
    <meta charset="utf-8">
    <title>#{esc(title)}</title>
    <document-view>
      <h1>#{esc(title)}</h1>
      <document-outline>
    #{Enum.map_join(units, "\n", &outline_item/1)}
      </document-outline>

      <work-flow>
    #{Enum.map_join(g.edges, "\n", &edge_el/1)}
      </work-flow>

    #{Enum.map_join(units, "\n", &unit_section(&1, g))}
    </document-view>
    """
  end

  defp outline_item(n), do: ~s(    <work-ref to="#{esc(n.id)}">#{esc(n.id)}</work-ref>)

  defp edge_el(e) do
    ~s(    <work-ref rel="#{e.type}" scope="#{e[:scope]}" layer="#{e[:layer]}" from="#{esc(e.from)}" to="#{esc(e.to)}"></work-ref>)
  end

  defp unit_section(n, g) do
    src = n.facets.source
    caps = Graph.host_caps(g, n.id)
    deps = Graph.dependencies(g, n.id)

    """
    <section id="#{esc(n.id)}" data-kind="#{esc(n.kind)}" data-lang="#{esc(n.lang)}">
      <h2>#{esc(n.id)}</h2>
      <record-view>
        <record-field-value name="kind">#{esc(n.kind)}</record-field-value>
        <record-field-value name="lang">#{esc(n.lang)}</record-field-value>
        <record-field-value name="package">#{esc(n.uid.package)}</record-field-value>
        <record-field-value name="exports">#{esc(Enum.map_join(src.exports, ", ", &export_label/1))}</record-field-value>
        <record-field-value name="depends-on">#{esc(Enum.join(deps, ", "))}</record-field-value>
        <record-field-value name="host-caps">#{esc(Enum.join(caps, ", "))}</record-field-value>
        <record-field-value name="artifact">#{esc(artifact_label(n.facets.artifact))}</record-field-value>
      </record-view>
    </section>
    """
  end

  defp export_label({name, _types}), do: to_string(name)
  defp export_label(name), do: to_string(name)

  defp artifact_label(nil), do: "—"
  defp artifact_label(%{exports: ex}), do: "compiled · exports: " <> Enum.join(ex, ", ")

  defp esc(v) do
    v
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
