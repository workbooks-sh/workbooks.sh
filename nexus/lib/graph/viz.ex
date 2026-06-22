defmodule Nexus.Graph.Viz do
  @moduledoc """
  A force-directed, interactive visualization of the unified graph. Units are nodes
  colored by kind; the *concepts they share* — capabilities and types — become hub
  nodes, so units that touch the same capability or type pull together into clusters
  (the implicit associations the explicit import edges miss). Subsystems (top-level
  folders) form labelled clusters. Physics + drag + zoom + hover; click a node to
  inspect its declared vs reality layers. Self-contained HTML, offline.
  """

  alias Nexus.Graph

  @kind %{
    "resource" => {"#a8d4f0", "resource"},
    "server" => {"#aee5c2", "server"},
    "agent" => {"#f3c5a3", "agent"},
    "rust" => {"#f2ddb0", "wasm"},
    "zig" => {"#f2ddb0", "wasm"},
    "c" => {"#f2ddb0", "wasm"},
    "cpp" => {"#f2ddb0", "wasm"},
    "client" => {"#c8e0b0", "client"}
  }
  @cap_color "#f0a878"
  @type_color "#c9a0f0"

  def to_html(%Graph{} = g, opts \\ []) do
    title = Keyword.get(opts, :title, "System graph")
    units = Graph.units(g)
    {nodes, links} = model(g, units)

    """
    <!doctype html>
    <meta charset="utf-8">
    <meta name="darkreader-lock">
    <title>#{esc(title)}</title>
    <style>#{css()}</style>
    <body>
    <header>
      <h1>#{esc(title)}</h1>
      <p class="sub">Units cluster around the <b>capabilities</b> and <b>types</b> they share. Drag to pull · scroll to zoom · hover to focus · click to inspect.</p>
      <div class="bar">
        <span class="lbl">edges:</span>
        <label class="tog work on"><input type="checkbox" data-layer="work" checked><i></i>work-file</label>
        <label class="tog native on"><input type="checkbox" data-layer="native" checked><i></i>native (BEAM)</label>
        <label class="tog wasm on"><input type="checkbox" data-layer="wasm" checked><i></i>wasm (WIT)</label>
        <span class="lbl" style="margin-left:18px">nodes:</span>
        <div class="legend">#{legend()}</div>
        <span class="lbl" style="margin-left:18px" title="the small dots on a node show which live overlay layers it has">reality dots:</span>
        <div class="legend">#{reality_legend()}</div>
      </div>
    </header>
    <div class="stage">
      <svg id="svg"><g id="view">
        <g id="hulls"></g><g id="links"></g><g id="nodes"></g>
      </g></svg>
      <aside id="panel"><p class="hint">Click a node to inspect its layers.</p></aside>
    </div>
    <script>
    const NODES = #{json(nodes)};
    const LINKS = #{json(links)};
    #{sim_js()}
    </script>
    </body>
    """
  end

  # ── build nodes (units + capability/type hubs) and links ──
  defp model(g, units) do
    subsystem = fn n -> n.file |> Path.dirname() |> Path.split() |> List.last() |> case_root() end

    unit_nodes =
      Enum.map(units, fn n ->
        {color, klabel} = Map.get(@kind, n.kind, {"#e6e3d8", n.kind})

        %{
          id: "u:" <> n.id,
          label: n.id,
          type: "unit",
          klass: klabel,
          group: subsystem.(n),
          color: color,
          badges: badges(n.facets),
          r: 13 + 2 * length(Graph.dependencies(g, n.id)),
          detail: detail(g, n)
        }
      end)

    # capability hubs — a unit links to every host-cap it grants; shared caps cluster units.
    # The unit↔cap edge lives on the WEBASSEMBLY side (the WIT/Dock import boundary).
    caps = units |> Enum.flat_map(&Graph.host_caps(g, &1.id)) |> Enum.uniq()
    cap_nodes = Enum.map(caps, &concept_node("cap:" <> &1, &1, "cap", @cap_color))

    cap_links =
      for u <- units, c <- Graph.host_caps(g, u.id),
          do: %{source: "u:" <> u.id, target: "cap:" <> c, type: "cap", layer: "wasm"}

    # type hubs — a unit links to every workbook type it declares or references. Types
    # are an authored shape → the WORK-FILE side.
    type_index = Map.keys(g.types)
    type_nodes = Enum.map(type_index, &concept_node("type:" <> &1, &1, "type", @type_color))

    type_links =
      for u <- units, t <- unit_types(u, type_index), do: %{source: "u:" <> u.id, target: "type:" <> t, type: "type", layer: "work"}

    # explicit unit→unit edges, classified by which side they live on:
    #   :ref (literate mention)            → WORK-FILE
    #   import from a wasm component        → WEBASSEMBLY (a `work://` component import)
    #   import from a server (Elixir call)  → NATIVE (BEAM)
    kinds = Map.new(units, &{&1.id, &1.kind})

    unit_links =
      for e <- g.edges, e.scope == :unit, Map.has_key?(node_set(units), e.from), Map.has_key?(node_set(units), e.to) do
        layer =
          cond do
            e.type == :ref -> "work"
            wasm_kind?(Map.get(kinds, e.from)) -> "wasm"
            true -> "native"
          end

        %{source: "u:" <> e.from, target: "u:" <> e.to, type: to_string(e.type), layer: layer}
      end

    nodes = unit_nodes ++ cap_nodes ++ type_nodes
    links = (unit_links ++ cap_links ++ type_links) |> Enum.uniq()
    {nodes, links}
  end

  defp concept_node(id, label, type, color),
    do: %{id: id, label: label, type: type, klass: type, group: id, color: color, badges: [], r: 9, detail: nil}

  @wasm_kinds ~w(client sandbox rust zig c cpp python svelte solid js ts)
  defp wasm_kind?(k), do: k in @wasm_kinds
  defp node_set(units), do: Map.new(units, &{&1.id, true})
  defp case_root(""), do: "core"
  defp case_root(s), do: s

  # the workbook types a unit declares or references (by WIT name in the registry)
  defp unit_types(u, type_index) do
    declared = for {kind, _} <- u.facets.source.types, kind in [:record, :enum, :module], do: Nexus.Uid.wit(u.id)

    referenced =
      u.facets.source.exports
      |> Enum.flat_map(fn
        {_n, ts} when is_list(ts) -> ts
        _ -> []
      end)

    (declared ++ referenced) |> Enum.filter(&(&1 in type_index)) |> Enum.uniq()
  end

  defp badges(f) do
    [
      {f[:interface] != nil, "interface"},
      {f[:artifact] != nil, "artifact"},
      {is_map(f[:data]) and map_size(Map.delete(f.data, :module)) > 0, "data"},
      {f[:observed] != nil, "telemetry"}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp detail(g, n) do
    %{
      kind: n.kind,
      lang: n.lang,
      package: n.uid.package,
      exports: Enum.map(n.facets.source.exports, &elem_label/1),
      deps: Graph.dependencies(g, n.id),
      caps: Graph.host_caps(g, n.id),
      interface: n.facets.interface != nil,
      artifact: kv(n.facets.artifact),
      data: kv(Map.delete(n.facets.data, :module)),
      observed: kv(n.facets.observed)
    }
  end

  defp elem_label({a, _}), do: to_string(a)
  defp elem_label(a), do: to_string(a)
  defp kv(nil), do: ""
  defp kv(m) when is_map(m), do: m |> Map.drop([:wit, :columns, :declared]) |> Enum.map_join(" · ", fn {k, v} -> "#{k}: #{val(v)}" end)
  defp val(v) when is_map(v), do: "{…}"
  defp val(v) when is_list(v), do: Enum.join(v, ",")
  defp val(v), do: to_string(v)

  defp legend do
    [
      {"#a8d4f0", "resource"}, {"#aee5c2", "server"}, {"#f3c5a3", "agent"}, {"#f2ddb0", "wasm"},
      {@cap_color, "● capability"}, {@type_color, "● type"}
    ]
    |> Enum.map_join("", fn {c, l} -> ~s|<span><i style="background:#{c}"></i>#{esc(l)}</span>| end)
  end

  # decodes the small dots that sit on a node — each = one live overlay layer present
  defp reality_legend do
    [{"#7fd6a0", "interface"}, {"#c9a0f0", "artifact"}, {"#8fb9f0", "data"}, {"#f0a878", "telemetry"}]
    |> Enum.map_join("", fn {c, l} -> ~s|<span><b class="pip" style="background:#{c}"></b>#{esc(l)}</span>| end)
  end

  defp json(t), do: t |> jsonable() |> Jason.encode!()
  defp jsonable(m) when is_map(m) and not is_struct(m), do: Map.new(m, fn {k, v} -> {k, jsonable(v)} end)
  defp jsonable(l) when is_list(l), do: Enum.map(l, &jsonable/1)
  defp jsonable(a) when is_atom(a) and not is_boolean(a) and not is_nil(a), do: to_string(a)
  defp jsonable(v), do: v

  defp esc(v), do: v |> to_string() |> String.replace("&", "&amp;") |> String.replace("<", "&lt;") |> String.replace(">", "&gt;") |> String.replace("\"", "&quot;")

  defp css do
    """
    *{box-sizing:border-box} html,body{height:100%;margin:0}
    body{background:#f7f6f1;color:#121316;font:13px/1.45 ui-sans-serif,system-ui,'Geist',sans-serif;display:flex;flex-direction:column}
    header{padding:14px 22px;border-bottom:1px solid #e6e3d8;flex:0 0 auto} h1{margin:0;font-size:18px}
    .sub{margin:4px 0 8px;color:#6b7382;font-size:12px} .sub b{color:#121316;font-weight:600}
    .legend{display:flex;flex-wrap:wrap;gap:14px;font-size:12px;color:#444}
    .legend span{display:inline-flex;align-items:center;gap:5px} .legend i{width:11px;height:11px;border-radius:3px;display:inline-block;border:1px solid #1213161a}
    .pip{width:10px;height:10px;border-radius:50%;display:inline-block;border:1px solid #1213161a}
    .bar{display:flex;align-items:center;gap:10px;flex-wrap:wrap;margin-top:9px} .lbl{font-size:11px;color:#9aa1ad;text-transform:uppercase;letter-spacing:.06em}
    .tog{display:inline-flex;align-items:center;gap:6px;font-size:12px;padding:3px 9px;border:1px solid #e6e3d8;border-radius:20px;cursor:pointer;color:#6b7382;user-select:none}
    .tog input{display:none} .tog i{width:14px;height:0;border-top:3px solid #ccc;border-radius:2px} .tog.on{color:#121316;background:#fff}
    .tog.work.on{border-color:#b3a36e} .tog.work.on i{border-color:#b3a36e} .tog.native.on{border-color:#5b9bd5} .tog.native.on i{border-color:#5b9bd5}
    .tog.wasm.on{border-color:#b07fe0} .tog.wasm.on i{border-color:#b07fe0} .tog:not(.on) i{border-top-style:dashed}
    .stage{flex:1;display:flex;min-height:0} #svg{flex:1;background:#fbfaf3;cursor:grab} #svg.drag{cursor:grabbing}
    .link{stroke-width:1.4;transition:opacity .15s} .link.work{stroke:#b3a36e99} .link.native{stroke:#5b9bd5;stroke-width:1.8} .link.wasm{stroke:#b07fe099}
    .link.ref{stroke-dasharray:3 3} .link.hidden{display:none}
    .node{cursor:pointer} .node text{font-size:11px;font-weight:600;paint-order:stroke;stroke:#fbfaf3;stroke-width:3px} .node.hub text{font-size:10px;font-weight:500;fill:#5a3d6b}
    .node.cap text{fill:#8a4a22} .node circle{stroke:#121316;stroke-width:1.5} .node.hub circle{stroke-width:1} .badge{stroke:#121316;stroke-width:.7}
    .dim{opacity:.12} .sel circle{stroke-width:3.5}
    .hull{fill:#12131608;stroke:#12131618;stroke-width:1} .hull-label{fill:#9aa1ad;font-size:12px;font-weight:600;letter-spacing:.04em}
    #panel{width:320px;flex:0 0 auto;border-left:1px solid #e6e3d8;background:#fff;padding:16px 18px;overflow:auto}
    #panel h2{margin:0 0 2px;font-size:17px} .tag{color:#6b7382;font-size:12px;margin-bottom:12px}
    .lay{margin:12px 0;padding-top:9px;border-top:1px dashed #e6e3d8} .lay h3{margin:0 0 7px;font-size:10px;letter-spacing:.08em;text-transform:uppercase;color:#9aa1ad}
    .r{display:flex;gap:8px;margin:5px 0} .r b{flex:0 0 84px;color:#6b7382;font-weight:500} .r span{flex:1}
    .hint{color:#9aa1ad}
    """
  end

  # the force simulation + interaction, vanilla JS (no deps, offline)
  defp sim_js do
    """
    const svg=document.getElementById('svg'), view=document.getElementById('view');
    const gN=document.getElementById('nodes'), gL=document.getElementById('links'), gH=document.getElementById('hulls');
    const SVGNS='http://www.w3.org/2000/svg';
    let W=svg.clientWidth, H=svg.clientHeight;
    const byId=Object.fromEntries(NODES.map(n=>[n.id,n]));
    NODES.forEach((n,i)=>{ const a=i*2.4; n.x=W/2+Math.cos(a)*(80+i*6); n.y=H/2+Math.sin(a)*(80+i*6); n.vx=0; n.vy=0; });
    LINKS.forEach(l=>{ l.s=byId[l.source]; l.t=byId[l.target]; l.len=l.type==='cap'||l.type==='type'?64:l.type==='import'?96:120; l.k=l.type==='cap'||l.type==='type'?0.06:0.03; });
    const adj={}; NODES.forEach(n=>adj[n.id]=new Set());
    LINKS.forEach(l=>{ if(l.s&&l.t){adj[l.s.id].add(l.t.id); adj[l.t.id].add(l.s.id);} });

    // elements
    const lineEls=LINKS.filter(l=>l.s&&l.t).map(l=>{ const e=document.createElementNS(SVGNS,'line'); e.setAttribute('class','link '+l.layer+' '+l.type); gL.appendChild(e); l.el=e; return l; });
    const hullEls={}; [...new Set(NODES.filter(n=>n.type==='unit').map(n=>n.group))].forEach(grp=>{
      const c=document.createElementNS(SVGNS,'circle'); c.setAttribute('class','hull'); gH.appendChild(c);
      const t=document.createElementNS(SVGNS,'text'); t.setAttribute('class','hull-label'); t.textContent=grp; gH.appendChild(t);
      hullEls[grp]={c,t};
    });
    NODES.forEach(n=>{
      const gg=document.createElementNS(SVGNS,'g'); gg.setAttribute('class','node '+(n.type!=='unit'?'hub '+n.type:'')); gg.dataset.id=n.id;
      const c=document.createElementNS(SVGNS,'circle'); c.setAttribute('r',n.r); c.setAttribute('fill',n.color); gg.appendChild(c);
      const nb=(n.badges||[]).length;
      (n.badges||[]).forEach((b,i)=>{ const bc=document.createElementNS(SVGNS,'circle'); bc.setAttribute('class','badge'); bc.setAttribute('r',4); bc.setAttribute('cx',(i-(nb-1)/2)*11); bc.setAttribute('cy',-(n.r+9)); bc.setAttribute('fill',{interface:'#7fd6a0',artifact:'#c9a0f0',data:'#8fb9f0',telemetry:'#f0a878'}[b]); gg.appendChild(bc); });
      const t=document.createElementNS(SVGNS,'text'); t.setAttribute('text-anchor','middle'); t.setAttribute('dy', n.type==='unit'? n.r+12 : 3); t.setAttribute('fill','#121316'); t.textContent=n.label; gg.appendChild(t);
      gN.appendChild(gg); n.el=gg;
      gg.addEventListener('pointerdown',e=>startDrag(e,n));
      gg.addEventListener('pointerenter',()=>focus(n)); gg.addEventListener('pointerleave',unfocus);
      gg.addEventListener('click',()=>select(n));
    });

    let alpha=1;
    function centroids(){ const g={}; NODES.forEach(n=>{ if(n.type!=='unit')return; (g[n.group]=g[n.group]||{x:0,y:0,c:0}); g[n.group].x+=n.x; g[n.group].y+=n.y; g[n.group].c++; }); for(const k in g){g[k].x/=g[k].c;g[k].y/=g[k].c;} return g; }
    let frame=0;
    function step(){
      for(let i=0;i<NODES.length;i++)for(let j=i+1;j<NODES.length;j++){ const a=NODES[i],b=NODES[j]; let dx=a.x-b.x,dy=a.y-b.y,d2=dx*dx+dy*dy||1,d=Math.sqrt(d2); const f=1300/d2,ux=dx/d,uy=dy/d; a.vx+=ux*f;a.vy+=uy*f;b.vx-=ux*f;b.vy-=uy*f; }
      lineEls.forEach(l=>{ const a=l.s,b=l.t; let dx=b.x-a.x,dy=b.y-a.y,d=Math.hypot(dx,dy)||1; const f=(d-l.len)*l.k*alpha,ux=dx/d,uy=dy/d; a.vx+=ux*f;a.vy+=uy*f;b.vx-=ux*f;b.vy-=uy*f; });
      const cen=centroids();
      NODES.forEach(n=>{ if(n.type==='unit'){const c=cen[n.group]; n.vx+=(c.x-n.x)*0.07*alpha; n.vy+=(c.y-n.y)*0.07*alpha;} n.vx+=(W/2-n.x)*0.004*alpha; n.vy+=(H/2-n.y)*0.004*alpha; });
      NODES.forEach(n=>{ if(n.fx!=null){n.x=n.fx;n.y=n.fy;n.vx=n.vy=0;return;} n.vx*=0.82;n.vy*=0.82; n.x+=n.vx;n.y+=n.vy; });
      alpha+=(0.04-alpha)*0.02;
      draw(cen);
      frame++;
      if(frame>1 && frame<260 && !drag) fitView();
      requestAnimationFrame(step);
    }
    function draw(cen){
      lineEls.forEach(l=>{ l.el.setAttribute('x1',l.s.x);l.el.setAttribute('y1',l.s.y);l.el.setAttribute('x2',l.t.x);l.el.setAttribute('y2',l.t.y); });
      NODES.forEach(n=>n.el.setAttribute('transform',`translate(${n.x},${n.y})`));
      for(const grp in hullEls){ const m=NODES.filter(n=>n.type==='unit'&&n.group===grp); if(!m.length)continue; const c=cen[grp]; let R=40; m.forEach(n=>R=Math.max(R,Math.hypot(n.x-c.x,n.y-c.y)+n.r)); const h=hullEls[grp]; h.c.setAttribute('cx',c.x);h.c.setAttribute('cy',c.y);h.c.setAttribute('r',R+18); h.t.setAttribute('x',c.x);h.t.setAttribute('y',c.y-R-24); h.t.setAttribute('text-anchor','middle'); }
    }
    requestAnimationFrame(step);

    // hover focus
    function focus(n){ const keep=new Set([n.id,...adj[n.id]]); NODES.forEach(m=>m.el.classList.toggle('dim',!keep.has(m.id))); lineEls.forEach(l=>l.el.classList.toggle('dim', l.s.id!==n.id&&l.t.id!==n.id)); }
    function unfocus(){ NODES.forEach(m=>m.el.classList.remove('dim')); lineEls.forEach(l=>l.el.classList.remove('dim')); }

    // drag
    let drag=null;
    function startDrag(e,n){ e.stopPropagation(); drag=n; n.fx=n.x;n.fy=n.y; alpha=0.6; svg.setPointerCapture(e.pointerId); }
    svg.addEventListener('pointermove',e=>{ if(drag){ const p=toView(e); drag.fx=p.x;drag.fy=p.y; } else if(pan){ tx+=e.movementX; ty+=e.movementY; apply(); } });
    svg.addEventListener('pointerup',()=>{ if(drag){drag.fx=drag.fy=null;drag=null;} pan=false; svg.classList.remove('drag'); });

    // zoom + pan
    let tx=0,ty=0,scale=1,pan=false;
    function apply(){ view.setAttribute('transform',`translate(${tx},${ty}) scale(${scale})`); }
    function fitView(){ const xs=NODES.map(n=>n.x), ys=NODES.map(n=>n.y); const a=Math.min(...xs)-70,b=Math.max(...xs)+70,c=Math.min(...ys)-70,d=Math.max(...ys)+70; scale=Math.min(1.6,Math.max(0.25,Math.min(W/(b-a),H/(d-c)))); tx=W/2-(a+b)/2*scale; ty=H/2-(c+d)/2*scale; apply(); }
    svg.addEventListener('dblclick',fitView);
    function toView(e){ const r=svg.getBoundingClientRect(); return {x:(e.clientX-r.left-tx)/scale, y:(e.clientY-r.top-ty)/scale}; }
    svg.addEventListener('pointerdown',e=>{ if(e.target===svg||e.target===view){pan=true;svg.classList.add('drag');} });
    svg.addEventListener('wheel',e=>{ e.preventDefault(); const r=svg.getBoundingClientRect(),mx=e.clientX-r.left,my=e.clientY-r.top; const s=Math.exp(-e.deltaY*0.0012); const ns=Math.min(2.5,Math.max(0.3,scale*s)); tx=mx-(mx-tx)*(ns/scale); ty=my-(my-ty)*(ns/scale); scale=ns; apply(); },{passive:false});
    window.addEventListener('resize',()=>{ W=svg.clientWidth;H=svg.clientHeight; });

    // inspect panel
    const panel=document.getElementById('panel');
    function row(k,v){ return v&&v.length?`<div class="r"><b>${k}</b><span>${v}</span></div>`:''; }
    function select(n){
      NODES.forEach(m=>m.el.classList.remove('sel')); n.el.classList.add('sel');
      if(n.type!=='unit'){ panel.innerHTML=`<h2>${n.label}</h2><div class="tag">${n.klass} · shared concept</div><p class="hint">A ${n.klass} hub — every unit linked here ${n.klass==='cap'?'grants this capability':'uses this type'}.</p>`; return; }
      const d=n.detail;
      panel.innerHTML=`<h2>${n.label}</h2><div class="tag">${d.kind} · ${d.lang||'—'}</div>`
        +`<div class="lay"><h3>declared</h3>`+row('package',d.package)+row('exports',d.exports.join(', '))+row('depends on',d.deps.join(', '))+row('host caps',d.caps.join(', '))+row('interface',d.interface?'WIT world ✓':'')+`</div>`
        +`<div class="lay"><h3>reality</h3>`+row('artifact',d.artifact)+row('data',d.data)+row('telemetry',d.observed)+((d.artifact||d.data||d.observed)?'':'<p class="hint">no reality overlay attached</p>')+`</div>`;
    }

    // layer toggles — show only the work-file / native / wasm sides of the graph
    const active={work:true,native:true,wasm:true};
    document.querySelectorAll('.tog input').forEach(cb=>cb.addEventListener('change',()=>{ active[cb.dataset.layer]=cb.checked; cb.closest('.tog').classList.toggle('on',cb.checked); applyLayers(); alpha=0.5; }));
    function applyLayers(){
      lineEls.forEach(l=>l.el.classList.toggle('hidden',!active[l.layer]));
      NODES.forEach(n=>{ if(n.type==='unit')return; const vis=lineEls.some(l=>(l.s.id===n.id||l.t.id===n.id)&&active[l.layer]); n.el.style.display=vis?'':'none'; });
    }
    applyLayers();
    """
  end
end
