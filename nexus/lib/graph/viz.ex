defmodule Nexus.Graph.Viz do
  @moduledoc """
  A visual (SVG) render of the unified graph — nodes by kind, typed edges, and a
  badge per node for each *reality source* present (interface/artifact/data/
  observed). Self-contained HTML: open it in any browser, click a node to inspect
  its layers. Dogfood sibling of `Nexus.Graph.Render` (which emits the work-*
  workbook); this one is the at-a-glance picture.
  """

  alias Nexus.Graph

  @kind_color %{
    "resource" => "#a8d4f0",
    "record" => "#a8d4f0",
    "server" => "#aee5c2",
    "agent" => "#f3c5a3",
    "rust" => "#f2ddb0",
    "zig" => "#f2ddb0",
    "c" => "#f2ddb0",
    "client" => "#c8e0b0"
  }
  @default_color "#e6e3d8"

  # left→right columns by role, so dependencies read across the page
  @columns ~w(resource record client server rust zig c cpp agent)

  def to_html(%Graph{} = g, opts \\ []) do
    title = Keyword.get(opts, :title, "System graph")
    nodes = Graph.units(g) |> Enum.sort_by(& &1.id)
    pos = layout(nodes)
    xs = pos |> Map.values() |> Enum.map(&elem(&1, 0))
    ys = pos |> Map.values() |> Enum.map(&elem(&1, 1))
    w = max(700, (Enum.max(xs, fn -> 0 end)) + 130)
    h = max(360, (Enum.max(ys, fn -> 0 end)) + 110)

    """
    <!doctype html>
    <meta charset="utf-8">
    <meta name="darkreader-lock">
    <title>#{esc(title)}</title>
    <style>#{css()}</style>
    <body>
    <header><h1>#{esc(title)}</h1>
      <div class="legend">#{legend()}</div></header>
    <div class="stage">
      <svg viewBox="0 0 #{w} #{h}" id="g">
        <defs><marker id="a" markerWidth="9" markerHeight="9" refX="7" refY="3" orient="auto">
          <path d="M0,0 L7,3 L0,6 Z" fill="#9aa1ad"/></marker></defs>
        #{Enum.map_join(g.edges, "\n    ", &edge_svg(&1, pos))}
        #{Enum.map_join(nodes, "\n    ", &node_svg(&1, pos))}
      </svg>
      <aside id="panel"><p class="hint">Click a node to inspect its layers.</p></aside>
    </div>
    <script>#{js(nodes, g)}</script>
    </body>
    """
  end

  # ── layout: dense column by role (only kinds present), stacked within the column ──
  defp layout(nodes) do
    # map each present kind to a dense column index, ordered by @columns
    order =
      nodes
      |> Enum.map(& &1.kind)
      |> Enum.uniq()
      |> Enum.sort_by(&(Enum.find_index(@columns, fn k -> k == &1 end) || 99))

    dense = order |> Enum.with_index() |> Map.new()

    nodes
    |> Enum.group_by(&Map.get(dense, &1.kind, map_size(dense)))
    |> Enum.flat_map(fn {ci, group} ->
      group
      |> Enum.sort_by(& &1.id)
      |> Enum.with_index()
      |> Enum.map(fn {n, ri} -> {n.id, {120 + ci * 170, 90 + ri * 120}} end)
    end)
    |> Map.new()
  end

  defp edge_svg(e, pos) do
    with {x1, y1} <- pos[e.from], {x2, y2} <- pos[e.to] do
      dash = if e[:scope] == :host_cap, do: ~s( stroke-dasharray="4 4"), else: ""
      mx = (x1 + x2) / 2
      ~s|<path class="edge" d="M#{x1},#{y1} C#{mx},#{y1} #{mx},#{y2} #{x2},#{y2}" fill="none" stroke="#9aa1ad" stroke-width="1.5"#{dash} marker-end="url(#a)"/>|
    else
      _ -> ""
    end
  end

  defp node_svg(n, pos) do
    {x, y} = pos[n.id]
    color = Map.get(@kind_color, n.kind, @default_color)
    badges = badges(n)

    ~s|<g class="node" data-id="#{esc(n.id)}" transform="translate(#{x},#{y})">| <>
      ~s(<rect x="-54" y="-22" width="108" height="44" rx="10" fill="#{color}" stroke="#121316" stroke-width="1.5"/>) <>
      ~s(<text class="nm" text-anchor="middle" y="-2">#{esc(n.id)}</text>) <>
      ~s(<text class="kn" text-anchor="middle" y="13">#{esc(n.kind)}</text>) <>
      badges <>
      ~s(</g>)
  end

  # a colored dot per reality source the node carries
  defp badges(n) do
    f = n.facets

    present =
      [
        {f[:interface] && f.interface != nil, "#7fd6a0", "WIT interface"},
        {f[:artifact] && f.artifact != nil, "#c9a0f0", "compiled artifact"},
        {is_map(f[:data]) && map_size(Map.delete(f.data, :module)) > 0, "#8fb9f0", "live data / schema"},
        {f[:observed] && f.observed != nil, "#f0a878", "telemetry"}
      ]
      |> Enum.filter(&elem(&1, 0))

    present
    |> Enum.with_index()
    |> Enum.map_join("", fn {{_, c, _}, i} ->
      ~s(<circle cx="#{-40 + i * 14}" cy="-30" r="4.5" fill="#{c}" stroke="#121316" stroke-width="0.8"/>)
    end)
  end

  defp legend do
    [
      {"#a8d4f0", "resource"},
      {"#aee5c2", "server"},
      {"#f3c5a3", "agent"},
      {"#f2ddb0", "wasm (rust/zig)"},
      {"#7fd6a0", "● interface"},
      {"#c9a0f0", "● artifact"},
      {"#8fb9f0", "● data"},
      {"#f0a878", "● telemetry"}
    ]
    |> Enum.map_join("", fn {c, l} -> ~s(<span><i style="background:#{c}"></i>#{esc(l)}</span>) end)
  end

  # facet detail embedded per node, rendered into the side panel on click
  defp js(nodes, g) do
    data =
      Map.new(nodes, fn n ->
        {n.id,
         %{
           kind: n.kind,
           lang: n.lang,
           package: n.uid.package,
           exports: Enum.map(n.facets.source.exports, &export_label/1),
           deps: Graph.dependencies(g, n.id),
           caps: Graph.host_caps(g, n.id),
           interface: not is_nil(n.facets.interface),
           artifact: facet_str(n.facets.artifact),
           data: data_str(n.facets.data),
           observed: facet_str(n.facets.observed)
         }}
      end)

    """
    const D = #{json(data)};
    const panel = document.getElementById('panel');
    function row(k,v){ return v && v.length ? `<div class="r"><b>${k}</b><span>${v}</span></div>` : ''; }
    document.querySelectorAll('.node').forEach(g => g.addEventListener('click', () => {
      document.querySelectorAll('.node').forEach(n=>n.classList.remove('sel'));
      g.classList.add('sel');
      const id = g.dataset.id, d = D[id];
      panel.innerHTML = `<h2>${id}</h2><div class="tag">${d.kind} · ${d.lang||'—'}</div>`
        + `<div class="lay"><h3>declared</h3>`
        + row('package', d.package) + row('exports', d.exports.join(', '))
        + row('depends on', d.deps.join(', ')) + row('host caps', d.caps.join(', '))
        + row('interface', d.interface ? 'WIT world ✓' : '') + `</div>`
        + `<div class="lay"><h3>reality</h3>`
        + row('artifact', d.artifact) + row('data', d.data) + row('telemetry', d.observed)
        + (d.artifact||d.data||d.observed ? '' : '<p class="hint">no reality overlay attached</p>') + `</div>`;
    }));
    """
  end

  defp export_label({n, _}), do: to_string(n)
  defp export_label(n), do: to_string(n)

  defp facet_str(nil), do: ""
  defp facet_str(m) when is_map(m) do
    m |> Map.drop([:wit, :columns, :declared]) |> Enum.map_join(" · ", fn {k, v} -> "#{k}: #{val(v)}" end)
  end

  defp data_str(m) when is_map(m) do
    case Map.delete(m, :module) do
      e when map_size(e) == 0 -> ""
      d -> d |> Map.drop([:declared, :columns]) |> Enum.map_join(" · ", fn {k, v} -> "#{k}: #{val(v)}" end)
    end
  end

  defp val(v) when is_map(v), do: "{…}"
  defp val(v) when is_list(v), do: Enum.join(v, ",")
  defp val(v), do: to_string(v)

  defp json(term), do: term |> jsonable() |> Jason.encode!()
  defp jsonable(m) when is_map(m) and not is_struct(m), do: Map.new(m, fn {k, v} -> {k, jsonable(v)} end)
  defp jsonable(l) when is_list(l), do: Enum.map(l, &jsonable/1)
  defp jsonable(a) when is_atom(a) and not is_boolean(a) and not is_nil(a), do: to_string(a)
  defp jsonable(v), do: v

  defp esc(v) do
    v |> to_string() |> String.replace("&", "&amp;") |> String.replace("<", "&lt;") |> String.replace(">", "&gt;") |> String.replace("\"", "&quot;")
  end

  defp css do
    """
    *{box-sizing:border-box} body{margin:0;background:#f7f6f1;color:#121316;font:14px/1.5 ui-sans-serif,system-ui,'Geist',sans-serif}
    header{padding:18px 24px;border-bottom:1px solid #e6e3d8} h1{margin:0 0 8px;font-size:19px}
    .legend{display:flex;flex-wrap:wrap;gap:14px;font-size:12px;color:#444}
    .legend span{display:inline-flex;align-items:center;gap:5px} .legend i{width:11px;height:11px;border-radius:3px;display:inline-block;border:1px solid #1213161a}
    .stage{display:flex;gap:0;height:calc(100vh - 86px)}
    svg{flex:1;background:#fbfaf3} .node{cursor:pointer} .node:hover rect{filter:brightness(0.97)}
    .node.sel rect{stroke-width:3} .nm{font-size:13px;font-weight:600} .kn{font-size:10px;fill:#5a6068}
    .edge{transition:stroke .15s}
    #panel{width:330px;border-left:1px solid #e6e3d8;background:#fff;padding:18px 20px;overflow:auto}
    #panel h2{margin:0 0 2px;font-size:18px} .tag{color:#6b7382;font-size:12px;margin-bottom:14px}
    .lay{margin:14px 0;padding-top:10px;border-top:1px dashed #e6e3d8} .lay h3{margin:0 0 8px;font-size:11px;letter-spacing:.08em;text-transform:uppercase;color:#9aa1ad}
    .r{display:flex;gap:8px;margin:5px 0;font-size:13px} .r b{flex:0 0 88px;color:#6b7382;font-weight:500} .r span{flex:1}
    .hint{color:#9aa1ad;font-size:13px}
    """
  end
end
