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
end
