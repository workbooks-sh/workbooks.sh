defmodule Workbooks.JsEngine do
  @moduledoc """
  FULL JavaScript engine in-sandbox — StarlingMonkey (SpiderMonkey compiled to wasm) as a runtime EVAL host.

  Spec-complete ECMAScript (arrow fns, Map/Set, Promise/async, spread, JSON, TextEncoder, the whole modern
  language) running ENTIRELY inside wasmtime: no V8, no native code generation (W^X-safe — SpiderMonkey ships a
  portable bytecode interpreter, not a JIT), no microVM. This is the full-JS-language upgrade over the QuickJS
  lane (ES2020-ish + partial). The engine (~10MB) is the vendored `@bytecodealliance/componentize-js`
  StarlingMonkey embedding.

  THE UNLOCK (verified 2026-06-13): componentize ONE fixed `run(src)` bootstrap that `eval`s its argument — a
  fixed host asset built once + cached — then feed ARBITRARY user JS at RUNTIME as the call argument (no rebuild
  per program). The only subtlety was a WASI version skew: jco 1.20 / componentize-js 0.21 emit components
  importing wasi:http@0.2.10, but our vendored wasmtime 39 provides 0.2.0/0.2.3/0.2.6. FIX (no wasmtime rebuild):
  build the eval-host with componentize-js@0.18.5 (pinned under the npm alias `componentize-js-023`), which emits
  wasi 0.2.3 — which wasmtime 39 links. Proven: eval("6*7") -> "42", plus Map/Set/Promise/async/spread all
  spec-correct on the production runtime.

  StarlingMonkey hard-imports wasi:http/io even for pure eval, so we instantiate with allow_http: true (that
  also routes any guest fetch() through the vendored WasiHttpView -> NetGuard, SSRF-safe — same brokered cadence
  as every Instance). weval `--aot` (a one-time engine specialization, vendored as
  `starlingmonkey_embedding_weval.wasm`) is a later drop-in speed flag.
  """
  require Logger

  @root Path.expand(Path.join(__DIR__, ".."))
  # build/cache is gitignored — the 10MB eval-host is a rebuildable cached asset, never committed.
  @cache Path.join(@root, "build/cache/jsengine")
  @host Path.join(@cache, "eval-host-023.wasm")

  # the fixed eval bootstrap — exports `run(input)` (the workbook world), eval's the JS, returns a string.
  # ASYNC bootstrap (wb js-ecosystem async-eventloop): eval the src, and if it yields a thenable, AWAIT it.
  # StarlingMonkey drives its internal event loop until this async export settles — so Promises, async/await,
  # and (with clocks enabled) setTimeout/streams all complete before we return. Sync programs are unaffected.
  @bootstrap ~S|export async function run(src){ try{ let r=(0,eval)(src); if(r&&typeof r.then==="function") r=await r; if(r===undefined) return "undefined"; if(typeof r==="object"&&r!==null){ try{ return JSON.stringify(r); }catch(_){ return String(r); } } return String(r); }catch(e){ return "ERR: "+(e&&e.message?e.message:String(e)); } }|

  @doc """
  Build the eval-host component once (componentize-js@0.18.5 / StarlingMonkey, cached). `{:ok, wasm_path}` |
  `{:error, why}`. Idempotent — returns the cached artifact if present.
  """
  def build_host do
    if File.exists?(@host) do
      {:ok, @host}
    else
      File.mkdir_p!(@cache)
      builder = Path.join(@cache, "build-host.mjs")
      # use the 0.2.3-targeting componentize (alias `componentize-js-023`) so the component links on wasmtime 39.
      File.write!(builder, """
      import { componentize } from 'componentize-js-023';
      import { writeFileSync } from 'node:fs';
      const src = #{Jason.encode!(@bootstrap)};
      const wit = "package wb:jseval;\\nworld workbook { export run: func(input: string) -> string; }";
      const { component } = await componentize(src, { witWorld: wit, worldName: "workbook", disableFeatures: ["random","stdio"] });
      writeFileSync(#{Jason.encode!(@host)}, component);
      console.log("OK " + component.length);
      """)

      case System.cmd("node", [builder], cd: @root, stderr_to_stdout: true) do
        {out, 0} ->
          if File.exists?(@host), do: {:ok, @host}, else: {:error, {:no_output, String.slice(out, 0, 300)}}

        {err, _} ->
          {:error, {:componentize_failed, String.slice(err, 0, 400)}}
      end
    end
  end

  @doc """
  Evaluate JS `src` in a fresh full-SpiderMonkey instance; `{:ok, result_string}` | `{:error, why}`. The result
  is the last expression coerced to a string (objects -> JSON). Spec-complete modern ECMAScript. opts:
    * `:timeout` (ms, default 12_000)
  Networking: a guest `fetch()` routes through the broker (SSRF-safe); enabled because StarlingMonkey requires
  the wasi:http import to link regardless.
  """
  def eval(src, opts \\ []) when is_binary(src) do
    timeout = Keyword.get(opts, :timeout, 12_000)

    with {:ok, host} <- build_host() do
      case Wasmex.Components.start_link(%{
             path: host,
             wasi: %Wasmex.Wasi.WasiP2Options{allow_http: true}
           }) do
        {:ok, pid} ->
          try do
            Wasmex.Components.call_function(pid, "run", [src], timeout)
          after
            if Process.alive?(pid), do: Process.exit(pid, :normal)
          end

        {:error, reason} ->
          {:error, {:instantiate_failed, reason}}
      end
    end
  end

  @doc """
  Run a self-contained JS/TS *program* (e.g. an esbuild bundle) and return its `console` output as
  `{:ok, stdout}` | `{:error, why}`. This is the GENERAL execution path for npm libraries.

  StarlingMonkey first (the full WHATWG platform — WebCrypto/`crypto.getRandomValues`+`randomUUID`,
  modern ES, `structuredClone`, brokered `fetch`), auto-falling back to the QuickJS lane only when
  StarlingMonkey hits its one known gap: regex `\\p{…}` unicode-property escapes (the `run` bootstrap
  surfaces that as `"ERR: … regular expression"`). QuickJS handles `\\p{}` but lacks WebCrypto — the two
  are complementary, so the thin fallback covers the residue while StarlingMonkey carries the common
  case (uuid/nanoid/zod/lodash/date-fns all run on SM; marked-class `\\p{}` users land on QuickJS).

  The SM eval-host has stdio disabled, so we shadow `console.*` into a buffer and return it as the eval
  value — making SM's output shape identical to the QuickJS command's stdout. `opts`: `:timeout` (SM
  eval ms); `:stdin`/`:argv` (QuickJS fallback only).
  """
  def run_program(js, opts \\ []) when is_binary(js) do
    case eval(console_capture(js), opts) do
      {:ok, "ERR: " <> msg} ->
        Logger.debug("JsEngine.run_program: StarlingMonkey eval failed (#{String.slice(msg, 0, 80)}); QuickJS fallback")
        quickjs_run(js, opts)

      {:error, reason} ->
        Logger.debug("JsEngine.run_program: StarlingMonkey host error #{inspect(reason)}; QuickJS fallback")
        quickjs_run(js, opts)

      {:ok, out} ->
        {:ok, out}
    end
  end

  # Shadow console.* so a program's logging becomes the eval's return value (SM has stdio disabled).
  # Set on globalThis BEFORE the bundle runs; the trailing expression is what `run`'s eval returns.
  # Format-robust for a self-contained esbuild bundle (no top-level import/export after bundling).
  defp console_capture(body) do
    # Run the bundle inside an async IIFE so its awaits settle, then drain a few macrotask turns (timers/
    # streams flush now that clocks are enabled) before returning the buffer. The async bootstrap awaits this.
    "globalThis.__wbout=[];{const __p=(...a)=>globalThis.__wbout.push(a.map(String).join(\" \"));" <>
      "globalThis.console={log:__p,error:__p,warn:__p,info:__p,debug:__p};}\n" <>
      "(async()=>{\n" <> body <> "\n" <>
      "for(let __i=0;__i<5;__i++){await new Promise(r=>setTimeout(r,0));}\n" <>
      "return globalThis.__wbout.join(\"\\n\");})()"
  end

  # QuickJS fallback: compile the bundle to a wasm command in-sandbox, run it; its console.log → stdout.
  defp quickjs_run(js, opts) do
    tmp = Path.join(System.tmp_dir!(), "jsfallback-#{:erlang.phash2(js)}.js")
    File.write!(tmp, js)

    try do
      case Workbooks.Compilers.js_compile_to_wasm(tmp) do
        {:ok, wasm, _logs} ->
          out =
            Workbooks.PackageManager.run(wasm, Keyword.get(opts, :stdin, ""), Keyword.get(opts, :argv, []))

          out = if is_tuple(out), do: elem(out, 0), else: out
          {:ok, String.trim_trailing(to_string(out))}

        {:error, _} = err ->
          err
      end
    after
      File.rm(tmp)
    end
  end
end
