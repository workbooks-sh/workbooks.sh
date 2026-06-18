defmodule Nexus.JsDom do
  @moduledoc """
  **The greenfield render path** — run a page's JavaScript against a *real DOM*, fully in wasmtime,
  no V8, no Chromium. We load **linkedom** (a server-grade pure-JS DOM) inside **StarlingMonkey**
  (`Nexus.JsEngine`), expose `document`/`window`/`location`/`navigator` as globals, then run the
  page's own scripts against it and serialize the hydrated DOM back to HTML.

  This is the engine that beats Boa: StarlingMonkey has no capacity wall and a real **event loop**
  (Promises/async settle), so framework JS runs. The DOM is JS (linkedom), so we dodge the
  539-hand-bound-interface wall. Per the research, we do NOT bridge live layout — geometry isn't
  needed here: computer-use acts by element number, and screenshots come from a one-way
  serialize → Blitz render. `render_html/2` gives the hydrated HTML; feed it to `Nexus.Browse.Blitz`
  for text/screenshot.

      Nexus.JsDom.render_html("<div id=app></div>", scripts: ["document.getElementById('app').innerHTML='<h1>hi</h1>'"])
      #=> {:ok, "<html>…<div id=\"app\"><h1>hi</h1></div>…"}
  """

  @doc """
  Run `scripts` against a real DOM seeded from `html`, return the hydrated, serialized HTML.

    * `:scripts` — list of JS source strings (the page's inlined `<script>` bodies), run in order
    * `:settle_ms` — let the event loop drain this long before serializing (default 0; bump for async)
    * `:timeout` — overall wasm wall-clock (default 30s)
  """
  def render_html(html, opts \\ []) when is_binary(html) do
    scripts = Keyword.get(opts, :scripts, [])
    settle = Keyword.get(opts, :settle_ms, 0)
    timeout = Keyword.get(opts, :timeout, 30_000)
    boxes = Keyword.get(opts, :boxes, nil)

    src = harness(html, scripts, settle, boxes)
    Nexus.JsEngine.eval(src, timeout: timeout)
  end

  @doc "Whether the JS-DOM bundle is staged."
  def available?, do: File.exists?(bundle_path()) and Nexus.JsEngine.available?()

  # ── the eval harness: linkedom + global DOM + page scripts + async serialize ────────────────
  defp harness(html, scripts, settle, boxes) do
    page = Enum.map_join(scripts, "\n;\n", &wrap_script/1)

    """
    #{bundle()}
    ;
    const { window, document } = linkedom.parseHTML(#{json(html)});
    globalThis.window = window;
    globalThis.document = document;
    globalThis.navigator = window.navigator;
    globalThis.location = window.location;
    globalThis.self = window;
    globalThis.HTMLElement = window.HTMLElement;
    globalThis.Node = window.Node;
    globalThis.customElements = window.customElements;
    #{shims()}
    #{geometry_bridge(boxes)}
    #{page}
    ;
    // Let microtasks/timers drain, then serialize the hydrated DOM (StarlingMonkey awaits this thenable).
    (async () => {
      await new Promise(r => setTimeout(r, #{settle}));
      return document.toString();
    })();
    """
  end

  # A page script must not abort the whole render if it throws — isolate each.
  defp wrap_script(js), do: "try { (function(){ #{js}\n })(); } catch (e) { /* page script error: */ }"

  # The browser-API shims linkedom lacks but framework hydration needs. Cheap and high-leverage (the
  # fidelity research's tier-2 win): without these, effect hooks throw or lazy/gated content never
  # appears. We chose linkedom + these shims over happy-dom on COMPUTE grounds — happy-dom is 4.6×
  # larger (2.2MB) and pulls node:fs, and StarlingMonkey has no JIT, so bundle eval cost is paid every
  # render. The observers report "visible" (the prerender convention) so IntersectionObserver-gated
  # content un-gates without needing real geometry; the geometry bridge (Blitz boxes) lands next for
  # the cases that need true numbers.
  defp shims do
    """
    (function(){
      const W = globalThis.window;
      const def = (o, k, v) => { if (o && typeof o[k] === 'undefined') o[k] = v; };
      const mm = (q) => ({ matches:false, media:String(q||''), onchange:null, addEventListener(){}, removeEventListener(){}, addListener(){}, removeListener(){}, dispatchEvent(){return false;} });
      def(globalThis, 'matchMedia', mm); def(W, 'matchMedia', mm);
      const raf = (cb) => setTimeout(() => cb(Date.now()), 16);
      const caf = (id) => clearTimeout(id);
      def(globalThis,'requestAnimationFrame',raf); def(W,'requestAnimationFrame',raf);
      def(globalThis,'cancelAnimationFrame',caf); def(W,'cancelAnimationFrame',caf);
      // Report every observed element as visible — un-gates lazy/virtualized content (prerender convention).
      class IO { constructor(cb){this.cb=cb;} observe(el){ try{ this.cb([{isIntersecting:true,intersectionRatio:1,target:el,time:Date.now(),boundingClientRect:(el.getBoundingClientRect&&el.getBoundingClientRect())||{}}], this);}catch(e){} } unobserve(){} disconnect(){} takeRecords(){return [];} }
      class RO { constructor(cb){this.cb=cb;} observe(el){ try{ this.cb([{target:el,contentRect:(el.getBoundingClientRect&&el.getBoundingClientRect())||{x:0,y:0,width:0,height:0,top:0,left:0,right:0,bottom:0}}], this);}catch(e){} } unobserve(){} disconnect(){} }
      def(globalThis,'IntersectionObserver',IO); def(W,'IntersectionObserver',IO);
      def(globalThis,'ResizeObserver',RO); def(W,'ResizeObserver',RO);
      const store = () => { const m=new Map(); return { getItem:k=>m.has(String(k))?m.get(String(k)):null, setItem:(k,v)=>m.set(String(k),String(v)), removeItem:k=>m.delete(String(k)), clear:()=>m.clear(), key:i=>[...m.keys()][i]??null, get length(){return m.size;} }; };
      def(globalThis,'localStorage',store()); def(W,'localStorage',W.localStorage||store());
      def(globalThis,'sessionStorage',store()); def(W,'sessionStorage',W.sessionStorage||store());
      const hist = { length:1, scrollRestoration:'auto', state:null, pushState(s){this.state=s;}, replaceState(s){this.state=s;}, back(){}, forward(){}, go(){} };
      def(globalThis,'history',hist); def(W,'history',W.history||hist);
      def(globalThis,'scrollTo',()=>{}); def(W,'scrollTo',()=>{}); def(W,'scrollBy',()=>{});
      def(W,'getComputedStyle', (el)=>({ getPropertyValue:()=> '', length:0 }));
      def(globalThis,'getComputedStyle', W.getComputedStyle);
    })();
    """
  end

  # The geometry bridge (the moat). When `boxes` is a map (even empty), we (1) stamp every element with
  # a deterministic `data-wb-nid` — by document order then creation order, so the ids match across the
  # measure pass and the final pass — and (2) patch `getBoundingClientRect`/`offset*`/`client*` on the
  # element prototype to read REAL Blitz/Taffy boxes injected here. Pass 1 runs with `boxes = {}` (all
  # zero) just to emit the nid-annotated HTML to measure; pass 2 runs with the measured boxes so
  # geometry-dependent JS (virtualized lists, measure-then-position) sees true numbers. `nil` = off.
  defp geometry_bridge(nil), do: ""

  defp geometry_bridge(boxes) do
    json = boxes |> Map.new(fn {nid, {x, y, w, h}} -> {nid, [x, y, w, h]} end) |> Jason.encode!()

    """
    (function(){
      const boxes = #{json};
      let __nid = 0;
      const stamp = (el) => { try { if (el && el.nodeType === 1 && el.setAttribute && !el.getAttribute('data-wb-nid')) el.setAttribute('data-wb-nid', String(++__nid)); } catch(e){} return el; };
      try { const all = document.querySelectorAll('*'); for (let i = 0; i < all.length; i++) stamp(all[i]); } catch(e){}
      const _ce = document.createElement.bind(document);
      document.createElement = function(tag){ return stamp(_ce(tag)); };
      const zero = {x:0,y:0,width:0,height:0,top:0,left:0,right:0,bottom:0};
      const rectFor = (el) => { try { const id = el.getAttribute && el.getAttribute('data-wb-nid'); const b = id && boxes[id]; if (b) return {x:b[0],y:b[1],width:b[2],height:b[3],top:b[1],left:b[0],right:b[0]+b[2],bottom:b[1]+b[3]}; } catch(e){} return zero; };
      const patch = (proto) => {
        if (!proto) return;
        try { proto.getBoundingClientRect = function(){ const r = Object.assign({}, rectFor(this)); r.toJSON = () => r; return r; }; } catch(e){}
        const g = (name, key) => { try { Object.defineProperty(proto, name, { configurable:true, get(){ return Math.round(rectFor(this)[key]); } }); } catch(e){} };
        g('offsetWidth','width'); g('offsetHeight','height'); g('clientWidth','width'); g('clientHeight','height'); g('offsetTop','top'); g('offsetLeft','left');
      };
      try { patch(window.Element && window.Element.prototype); } catch(e){}
      try { patch(window.HTMLElement && window.HTMLElement.prototype); } catch(e){}
      try { let p = Object.getPrototypeOf(document.createElement('div')); for (let i=0;i<3&&p;i++){ patch(p); p = Object.getPrototypeOf(p); } } catch(e){}
    })();
    """
  end

  defp bundle, do: File.read!(bundle_path())
  defp bundle_path, do: Application.get_env(:nexus, :jsdom_bundle, Path.join([File.cwd!(), "priv", "jsdom.js"]))

  # Encode an Elixir string as a JS string literal.
  defp json(s), do: Jason.encode!(s)
end
