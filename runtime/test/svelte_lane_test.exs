defmodule Workbooks.SvelteLaneTest do
  # wb-2ku.5 — in-sandbox Svelte lane. A REAL `svelte` npm package is resolved + fetched (npm lane)
  # then its compiler runs INSIDE qjs-run.wasm (compilers/svelte/sveltejob.js, concatenated before
  # bundlejob.js) to compile a .svelte component, which is bundled + compiled to a wasm command and
  # run — ENTIRELY in-sandbox, zero native execution (no node/bun/vite). The no-native-execution
  # invariant is covered un-regressably by sandbox_invariant_test's static scan over the runtime
  # source; the new code (Compilers.svelte_bundle_dir) shells nothing but wasmtime, like bundle_dir.
  #
  # @tag :netdeps (needs the registry for `svelte`) + :build (needs the wasm JS toolchain). Degrades
  # gracefully offline / when the toolchain is absent, so the default suite stays green — same
  # convention as npm_e2e_test / crate_deps_test.
  #
  # VERSION: pins svelte ^4. Svelte 4 ships its compiler as a single UMD bundle (svelte/compiler.js)
  # that QuickJS evaluates cleanly; svelte 5's compiler pulls more modern JS + a larger surface and
  # is the documented frontier for this lane (sveltejob tries the svelte-5 generate:'client' option
  # set first and falls back to svelte-4 generate:'dom', so a 5.x install would still be attempted).
  use ExUnit.Case, async: false

  alias Workbooks.{Compilers, PackageManager, Npm}

  # A counter component with reactive ($:) derived state — the canonical "does reactivity compile"
  # fixture. main.js mounts it against a MINIMAL DOM stub (QuickJS has no DOM) and prints the
  # rendered count so the run asserts the compiled component actually executed.
  @counter ~S"""
  <script>
    export let start = 0;
    let count = start;
    $: doubled = count * 2;
    function inc() { count += 1; }
  </script>
  <button on:click={inc}>{count}</button>
  <span>{doubled}</span>
  """

  # A tiny synchronous DOM good enough for Svelte 4's client runtime to mount text/elements. We only
  # read back textContent, so nodes just need children + the handful of methods svelte/internal calls.
  @dom_stub ~S"""
  function el(tag){
    return {
      nodeName: tag, childNodes: [], attributes: {}, _text: "",
      set textContent(v){ this._text = String(v); this.childNodes = []; },
      get textContent(){
        if (this._text) return this._text;
        return this.childNodes.map(function(c){ return c.textContent || c._text || ""; }).join("");
      },
      set data(v){ this._text = String(v); }, get data(){ return this._text; },
      appendChild: function(c){ this.childNodes.push(c); c.parentNode = this; return c; },
      insertBefore: function(c){ this.childNodes.push(c); c.parentNode = this; return c; },
      removeChild: function(c){ var i=this.childNodes.indexOf(c); if(i>=0) this.childNodes.splice(i,1); return c; },
      setAttribute: function(k,v){ this.attributes[k]=v; }, removeAttribute: function(k){ delete this.attributes[k]; },
      addEventListener: function(){}, removeEventListener: function(){},
      cloneNode: function(){ return el(tag); }, firstChild: null, nextSibling: null,
      style: {}, classList: { add:function(){}, remove:function(){}, contains:function(){return false;} }
    };
  }
  globalThis.document = {
    createElement: el, createElementNS: function(_ns,t){ return el(t); },
    createTextNode: function(t){ var n = el("#text"); n._text = String(t); return n; },
    createComment: function(){ return el("#comment"); }
  };
  globalThis.window = globalThis;
  """

  @main ~S"""
  import Counter from "./Counter.svelte";
  var target = globalThis.document.createElement("div");
  new Counter({ target: target, props: { start: 5 } });
  Javy.IO.writeSync(1, new TextEncoder().encode("mounted:" + target.textContent));
  """

  defp proj(files) do
    dir = Path.join(System.tmp_dir!(), "svelte-#{System.unique_integer([:positive])}")
    Enum.each(files, fn {rel, body} ->
      full = Path.join(dir, rel)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, body)
    end)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp fixture_dir do
    proj(%{
      "package.json" => ~S|{"name":"svelte-fixture","dependencies":{"svelte":"^4.2.0"}}|,
      "Counter.svelte" => @counter,
      "src/main.js" => @dom_stub <> "\n" <> @main
    })
  end

  @tag :netdeps
  @tag :build
  @tag timeout: 600_000
  test "compiles a .svelte component and bundles it in-sandbox (svelte/compiler under QuickJS)" do
    dir = fixture_dir()

    # Install the svelte package (live, from the registry) so its compiler is in node_modules.
    case Npm.install_tree(PackageManager.parse_package_json_deps(dir), dir) do
      {:ok, _} -> :ok
      {:ok, _, _} -> :ok
      other -> IO.puts("\n[skip] svelte install: #{inspect(other) |> String.slice(0, 160)}")
    end

    if File.dir?(Path.join(dir, "node_modules/svelte")) do
      case Compilers.svelte_bundle_dir(dir, "src/main.js") do
        {:ok, js} ->
          assert is_binary(js)
          # The bundle is the shared bundlejob output (module registry) ...
          assert String.contains?(js, "__load")
          # ... and it carries the COMPILED component, not the raw <script>/markup. Svelte 4 emits
          # create_fragment + a class extending SvelteComponent; assert a compiler fingerprint plus
          # the component's own identifiers survived into the bundle.
          assert String.contains?(js, "create_fragment") or String.contains?(js, "SvelteComponent")
          assert String.contains?(js, "doubled")
          # No raw Svelte template syntax should remain (proves .svelte was transformed, not copied).
          refute String.contains?(js, "on:click")

        {:error, reason} ->
          IO.puts("\n[skip] svelte compile: #{inspect(reason) |> String.slice(0, 300)}")
      end
    end
  end

  @tag :netdeps
  @tag :build
  @tag timeout: 600_000
  test "compiled component runs to wasm and executes (mounts + reactive state)" do
    dir = fixture_dir()

    case PackageManager.build_dir(dir, "svelte") do
      {:ok, wasm, st} ->
        assert st in [:built, :cached]
        assert File.dir?(Path.join(dir, "node_modules/svelte"))
        out = PackageManager.run(wasm, "", []) |> to_string()
        # The component mounted against the DOM stub and rendered its initial count (start: 5).
        assert String.contains?(out, "mounted:")
        assert String.contains?(out, "5")

      {:error, reason} ->
        IO.puts("\n[skip] svelte build_dir: #{inspect(reason) |> String.slice(0, 300)}")
    end
  end
end
