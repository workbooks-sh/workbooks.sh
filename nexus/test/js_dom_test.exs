defmodule Nexus.JsDomTest do
  # The greenfield render: StarlingMonkey + linkedom. Slow (instantiates an ~11MB JS engine) and needs
  # the gitignored engine wasm + bundle — tagged so the default suite stays fast.
  use ExUnit.Case, async: false
  @moduletag :greenfield

  @tag timeout: 120_000
  test "runs a CSR page's JS (sync + async) against a real DOM and serializes the hydrated HTML" do
    if Nexus.JsDom.available?() do
      html = "<html><body><div id=root></div></body></html>"

      scripts = [
        ~s|const r=document.getElementById("root"); const a=document.createElement("a"); a.textContent="Docs"; a.setAttribute("href","/docs"); r.appendChild(a);|,
        ~s|setTimeout(()=>{const p=document.createElement("p");p.textContent="async";document.getElementById("root").appendChild(p);},10);|
      ]

      assert {:ok, out} = Nexus.JsDom.render_html(html, scripts: scripts, settle_ms: 50, timeout: 90_000)
      assert out =~ ~s|<a href="/docs">Docs</a>|
      assert out =~ "<p>async</p>"
    else
      IO.puts("[skip] greenfield JS engine / bundle not staged")
    end
  end

  @tag timeout: 150_000
  test "G3: a CSR page renders its client-JS content as text via the :jsdom engine (SM+linkedom → Blitz)" do
    if Nexus.JsDom.available?() do
      csr = """
      <html><body><div id=root></div>
      <script>
        const r=document.getElementById("root");
        const h=document.createElement("h1"); h.textContent="Client rendered"; r.appendChild(h);
        ["one","two","three"].forEach(t=>{const li=document.createElement("li");li.textContent=t;r.appendChild(li)});
      </script></body></html>
      """

      assert {:ok, text} = Nexus.Browse.Blitz.render_html(csr, "https://example.com/app", engine: :jsdom, js_timeout: 90_000)
      assert text =~ "Client rendered"
      assert text =~ "three"
    else
      IO.puts("[skip] greenfield JS engine / bundle not staged")
    end
  end

  @tag timeout: 120_000
  test "browser-API shims unblock SPA hydration (matchMedia, requestAnimationFrame, IntersectionObserver)" do
    if Nexus.JsDom.available?() do
      html = "<html><body><div id=root></div></body></html>"

      scripts = [
        ~s|const root=document.getElementById("root");
           root.appendChild(Object.assign(document.createElement("p"),{textContent:"mm:"+window.matchMedia("(min-width:1px)").matches}));
           requestAnimationFrame(()=>root.appendChild(Object.assign(document.createElement("p"),{textContent:"raf"})));
           const s=document.createElement("section"); root.appendChild(s);
           new IntersectionObserver(e=>{ if(e[0].isIntersecting) s.innerHTML="<b>ungated</b>"; }).observe(s);|
      ]

      assert {:ok, out} = Nexus.JsDom.render_html(html, scripts: scripts, settle_ms: 50, timeout: 90_000)
      assert out =~ "raf"
      assert out =~ "ungated"
    else
      IO.puts("[skip] greenfield JS engine / bundle not staged")
    end
  end

  @tag timeout: 200_000
  test "geometry bridge: JS branching on getBoundingClientRect sees REAL Blitz layout (zero without it)" do
    if Nexus.JsDom.available?() do
      csr = """
      <html><head><style>#card{width:300px;height:140px}</style></head>
      <body><div id=card></div><div id=out></div>
      <script>
        const w=document.getElementById("card").getBoundingClientRect().width;
        document.getElementById("out").textContent = (w >= 250) ? ("WIDE:"+Math.round(w)) : ("ZERO:"+Math.round(w));
      </script></body></html>
      """

      # Plain JS-DOM: gBCR is 0 → the wide branch never fires.
      assert {:ok, plain} = Nexus.Browse.Blitz.hydrate(csr, "https://example.com/", [])
      assert plain =~ "ZERO:0"

      # With the bridge: real Blitz layout → 300px → the geometry-dependent branch fires.
      assert {:ok, bridged} = Nexus.Browse.Blitz.hydrate(csr, "https://example.com/", geometry: true)
      assert bridged =~ "WIDE:300"
    else
      IO.puts("[skip] greenfield JS engine / bundle not staged")
    end
  end
end
