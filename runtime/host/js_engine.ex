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

  # Node-compat layer (SLICE 0, wb-b9xv). The prelude installs require/module/process/Buffer +
  # a node:/bare resolver backed by these pure-JS shims (no caps, zero Javy.* refs). fs/child_process
  # are OUT OF SCOPE for SLICE 0 (those shims call Javy.* / need host imports — later slices).
  @js_root Path.join(@root, "compilers/js")
  @node_prelude Path.join(@js_root, "node-prelude.js")
  # Pure-JS Node builtins resolvable on StarlingMonkey. process is injected by the prelude itself
  # (host-supplied env/argv, buffered stdout) — NOT loaded from the Javy-bound process.js shim.
  @node_builtins ~w(path events util os querystring url string_decoder assert timers)
  # SM-lane shims that supersede the generic pure-JS ones when a capability is granted. child_process on
  # SM dispatches over fetch() to the ExecLoopback sentinel (the only host seam SM has) — NOT Javy.Exec.
  @sm_shim_dir Path.join(@js_root, "shims-sm")

  # the fixed eval bootstrap — exports `run(input)` (the workbook world), eval's the JS, returns a string.
  # ASYNC bootstrap (wb js-ecosystem async-eventloop): eval the src, and if it yields a thenable, AWAIT it.
  # StarlingMonkey drives its internal event loop until this async export settles — so Promises, async/await,
  # and (with clocks enabled) setTimeout/streams all complete before we return. Sync programs are unaffected.
  #
  # HOST-IMPORT seam (the keystone residency fix — wb-b9xv host-import): the world ALSO imports the
  # synchronous `wb:jseval/broker.host-call: func(req: string) -> string`. componentize-js binds it as the JS
  # `hostCall` import here; we stash it on `globalThis.__wbHostCall` so the RUNTIME-eval'd shims (which run
  # under classic `eval`, not ESM, so they cannot `import`) can reach it. A guest calls __wbHostCall(json) and
  # the BEAM host performs the actual op (exec/fs/creds/llm egress with the host-held key) and returns the
  # bytes WITHIN THE SAME synchronous call — so NO wasi:http future ever straddles a run() boundary, the http
  # resource table is never poisoned, and the component-model reentrancy guard is never tripped. This DISSOLVES
  # the cross-entry trap that forced "one turn per instance then recycle" — re-entry is a non-issue by
  # construction (componentize-js@0.18.5 README: imported funcs are always synchronous — exactly what we need).
  @bootstrap ~S|import { hostCall } from 'wb:jseval/broker'; globalThis.__wbHostCall = hostCall; export async function run(src){ try{ let r=(0,eval)(src); if(r&&typeof r.then==="function") r=await r; if(r===undefined) return "undefined"; if(typeof r==="object"&&r!==null){ try{ return JSON.stringify(r); }catch(_){ return String(r); } } return String(r); }catch(e){ return "ERR: "+(e&&e.message?e.message:String(e)); } }|

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
      // workbook world: exports run(), and IMPORTS the synchronous host-broker seam (wb:host/broker.host-call).
      // The import is what dissolves the cross-entry wasi:http trap — the agent loop's llm/fs/exec ops go
      // through this sync import (host performs them in-call), not through guest fetch()/wasi:http.
      const wit = "package wb:jseval;\\ninterface broker { host-call: func(req: string) -> string; }\\nworld workbook { import broker; export run: func(input: string) -> string; }";
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

  # The component-model namespace the eval-host imports the sync broker from — must match the WIT
  # interface id (`package wb:jseval; interface broker`) the bootstrap imports as `wb:jseval/broker`.
  @broker_namespace "wb:jseval/broker"
  @broker_func "host-call"

  @doc """
  Build the `imports:` map for `Wasmex.Components.start_link` wiring the synchronous host-broker seam
  (`wb:jseval/broker.host-call`) to `Workbooks.HostBroker`. ALWAYS supplied (the eval-host now IMPORTS this
  func, so instantiation would fail without it); a `nil` grant default-denies every op. The grant is captured
  HOST-SIDE in the closure, so a guest reaches only exactly the caps its session was granted (no token over
  this seam). This is the transport that DISSOLVES the cross-entry wasi:http re-entry trap — the agent loop's
  llm/fs/exec go through this sync import, completing in-call, so no pollable ever straddles a run() boundary.

  POSTURE GATE: the exec/fs/creds/oauth/llm ops this seam reaches are the SAME surface `Workbooks.Harness.
  enabled?/0` governs. The import is wired with the grant ONLY when the harness surface is permitted; in a
  forbidden posture (bare single-tenant with no WB_DESKTOP/WB_HARNESS) the grant is FORCED to nil → every op
  default-denies. The import stays LINKED (harmless — instantiation still succeeds) but carries no capability.

  CLOUD-ENABLE (acp-cloud-enable): the harness surface is now PERMITTED in multi-tenant, so the seam carries
  the grant there too. Safety is per-tenant ISOLATION on the grant itself, not nil-ing the seam: the grant
  principal + creds_scope are bound to the AUTH-VERIFIED tenant (Workbooks.HarnessPool.start_session, reached
  via the /api/harness/session web entrypoint), so a guest reaches only its OWN tenant's caps, and the broker
  rate/concurrency/budget/revocation key + keychain scope are tenant-true. A caller can never mint a grant for
  another tenant's principal (mint refuses principal-less exec; the pool overrides the principal).
  """
  def host_broker_imports(grant) do
    effective = if Workbooks.Harness.enabled?(), do: grant, else: nil
    %{@broker_namespace => %{@broker_func => {:fn, Workbooks.HostBroker.import_fn(effective)}}}
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
    grant = Keyword.get(opts, :grant, nil)

    with {:ok, host} <- build_host() do
      case Wasmex.Components.start_link(%{
             path: host,
             wasi: %Wasmex.Wasi.WasiP2Options{allow_http: true},
             imports: host_broker_imports(grant)
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
    # Capture console.* into a buffer, then IDLE-DRAIN the event loop before returning it. Two signals decide
    # "done": (1) in-flight fetch() count back to zero (instrumented below) — so we don't exit during the quiet
    # gap while a network request is pending, and (2) console output stable for several turns. A fixed turn
    # count is too short for real async (a fetch resolves after tens of ms). The async bootstrap awaits this.
    "globalThis.__wbout=[];globalThis.__pend=0;" <>
      "{const __p=(...a)=>globalThis.__wbout.push(a.map(String).join(\" \"));" <>
      "globalThis.console={log:__p,error:__p,warn:__p,info:__p,debug:__p};" <>
      "if(typeof fetch===\"function\"){const __of=fetch;globalThis.fetch=function(){globalThis.__pend++;" <>
      "const __r=__of.apply(this,arguments);Promise.resolve(__r).then(x=>x).catch(()=>{}).finally(()=>{globalThis.__pend--});return __r;};}}\n" <>
      "(async()=>{\n" <> body <> "\n" <>
      "let __l=-1,__s=0,__t=Date.now();\n" <>
      "while((globalThis.__pend>0||__s<6)&&(Date.now()-__t)<12000){await new Promise(r=>setTimeout(r,10));" <>
      "if(globalThis.__wbout.length===__l){__s++}else{__l=globalThis.__wbout.length;__s=0}}\n" <>
      "return globalThis.__wbout.join(\"\\n\");})()"
  end

  @doc """
  Run a Node-shaped JS script on StarlingMonkey (SLICE 0, wb-b9xv): prepend the Node-compat prelude
  (require/module/process/Buffer + a `node:`/bare resolver over the embedded pure-JS shims) so a
  bundle that `require('node:path')`/reads `process.argv`/`fetch`es loads instead of dying on line 1.

  Returns `{:ok, %{stdout: binary, stderr: binary, result: binary, exit_code: integer}}` | `{:error, why}`.

  opts:
    * `:env`     — map of String=>String injected as `process.env` (default `%{}`)
    * `:argv`    — list of strings for `process.argv` (default `["node", "script"]`)
    * `:timeout` — ms (default 12_000)

  Resolvable `node:` builtins this slice: #{Enum.join(@node_builtins, ", ")} (+ `process`, host-injected).
  `fs`/`child_process` are deliberately NOT resolvable yet (later slices wire host imports).
  """
  def run_node(src, opts \\ []) when is_binary(src) do
    env = Keyword.get(opts, :env, %{})
    argv = Keyword.get(opts, :argv, ["node", "script"])
    # exec grant (SLICE 1): `exec: [allow: true, commands: …, principal: …]` enables `require('child_process')`
    # on the SM lane — it dispatches over fetch() to the ExecLoopback sentinel → ExecBroker. Absent => no exec.
    exec_opts = Keyword.get(opts, :exec, nil)
    # fs grant (headless-JS path): `fs: [workdir: "/abs/dir", principal: …]` enables `require('node:fs')` /
    # `'fs/promises'` on the SM lane — it routes over fetch() to /__wb/fs, CONFINED to workdir. Absent => no fs.
    fs_opts = Keyword.get(opts, :fs, nil)

    with {:ok, prelude} <- File.read(@node_prelude),
         {:ok, shims} <- load_node_shims() do
      {shims, exec_seam, token, grant} = maybe_grant_caps(shims, exec_opts, fs_opts)
      # bind the SAME grant into the host-import so child_process/fs/dock-auth/llm ops over __wbHostCall are
      # authorized identically to the legacy fetch loopback (the shims prefer the sync import).
      opts = Keyword.put(opts, :grant, grant)

      # ESM-style bundles (`import`/`export`/`import.meta.url`) are illegal in the classic-eval lane. Rewrite
      # them to CJS so a real ESM bundle (createRequire(import.meta.url) ×N) loads instead of dying on line 1.
      src = esm_to_cjs(src)

      try do
        boot =
          Jason.encode!(
            %{
              "shims" => shims,
              "env" => env,
              "argv" => argv
            }
            |> then(fn m -> if exec_seam, do: Map.put(m, "exec", exec_seam), else: m end)
          )

      # One eval payload: (1) set the host-injection seam, (2) run the prelude IIFE (installs globals),
      # (3) run the user script inside an AWAITED async IIFE, (4) IDLE-DRAIN the event loop so async work
      #    (fetch/exec) flushes to the buffers, (5) return the buffered stdout/stderr + exit code as JSON.
      #
      # The async IIFE + idle-drain mirror console_capture/1: a synchronous wrapper returns BEFORE any
      # awaited fetch/exec resolves, so its stdout never reaches the host. We instrument fetch with an
      # in-flight counter (the prelude leaves __wbPend untouched if absent), then await until in-flight is
      # zero AND output is stable for several turns. The bootstrap's `run` awaits the returned thenable, so
      # StarlingMonkey drives its event loop until this settles. Sync scripts are unaffected (drain exits
      # immediately once stable). `await (async()=>{ <src> })()` preserves the user's top-level `await`.
      composed =
        "globalThis.__wbNode=" <>
          boot <>
          ";\n" <>
          prelude <>
          "\n;(async function(){\n" <>
          "globalThis.__wbPend=globalThis.__wbPend||0;\n" <>
          "if(typeof fetch===\"function\"&&!globalThis.__wbFetchWrapped){globalThis.__wbFetchWrapped=true;" <>
          "const __of=fetch;globalThis.fetch=function(){globalThis.__wbPend++;" <>
          "const __r=__of.apply(this,arguments);Promise.resolve(__r).then(x=>x).catch(()=>{}).finally(()=>{globalThis.__wbPend--});return __r;};}\n" <>
          # also count in-flight setTimeout callbacks so the drain doesn't exit during a quiet gap between
          # scheduled continuations (a 30ms timer leaves stdout empty until it fires — without this the
          # stability counter could trip first and we'd return mid-async, losing later output).
          "if(typeof setTimeout===\"function\"&&!globalThis.__wbTimerWrapped){globalThis.__wbTimerWrapped=true;" <>
          "const __ot=setTimeout;globalThis.__wbDrainTimer=__ot;globalThis.setTimeout=function(fn,ms){globalThis.__wbPend++;" <>
          "return __ot.call(this,function(){try{return fn&&fn.apply(this,arguments)}finally{globalThis.__wbPend--}},ms);};}\n" <>
          "try{ await (async()=>{\n" <>
          src <>
          "\n})(); }catch(e){ globalThis.__wbThrew=(e&&e.message)?e.message:String(e); (globalThis.__wbStderr||[]).push(globalThis.__wbThrew+\"\\n\"); if(globalThis.process) globalThis.process.exitCode=globalThis.process.exitCode||1; }\n" <>
          "const __drainT=globalThis.__wbTimerWrapped?(globalThis.__wbDrainTimer||setTimeout):setTimeout;\n" <>
          "let __l=-1,__s=0,__t=Date.now();\n" <>
          "while((globalThis.__wbPend>0||__s<6)&&(Date.now()-__t)<12000){await new Promise(r=>__drainT(r,10));" <>
          "const __n=(globalThis.__wbStdout||[]).length+(globalThis.__wbStderr||[]).length;" <>
          "if(__n===__l){__s++}else{__l=__n;__s=0}}\n" <>
          "return JSON.stringify({stdout:(globalThis.__wbStdout||[]).join(\"\"),stderr:(globalThis.__wbStderr||[]).join(\"\"),threw:(globalThis.__wbThrew||null),exit_code:(globalThis.process&&globalThis.process.exitCode)|0});" <>
          "\n})();"

      case eval(composed, opts) do
        {:ok, "ERR: " <> msg} ->
          {:error, {:node_eval_failed, msg}}

        {:ok, json} ->
          case Jason.decode(json) do
            # an UNCAUGHT throw with NO stdout surfaces as {:error, :node_eval_failed} (SLICE 0 contract:
            # a require-failure / load error is a hard failure, not a 0-exit run). A throw AFTER some output,
            # or a clean process.exit(n), stays {:ok, …} with the captured stderr + non-zero exit_code.
            {:ok, %{"stdout" => "", "threw" => msg}} when is_binary(msg) ->
              {:error, {:node_eval_failed, msg}}

            {:ok, %{"stdout" => o, "stderr" => e, "exit_code" => c}} ->
              {:ok, %{stdout: o, stderr: e, result: json, exit_code: c}}

            _ ->
              {:ok, %{stdout: json, stderr: "", result: json, exit_code: 0}}
          end

        {:error, _} = err ->
          err
        end
      after
        # single-run token: revoke as soon as the run ends so a leaked sentinel URL can't be replayed.
        if token, do: Workbooks.ExecLoopback.revoke(token)
      end
    end
  end

  @doc """
  Compose a Node-compat BOOT payload for the PERSISTENT lane (SLICE 2, `Workbooks.HarnessSession`): the
  `__wbNode` seam + the prelude IIFE + the shim registry, as ONE eval string. Run it ONCE on a live
  StarlingMonkey instance and `require`/`process`/`Buffer`/`__wbExec` persist on `globalThis` for every
  subsequent `run()` — exactly the resident-harness shape `run_node/2` builds per call, factored out so a
  persistent session installs the same Node platform without re-running the one-shot drain wrapper.

  `opts`: `:env` (process.env map), `:argv`, and the exec/llm seam either as a ready
  `%{"url" => …, "token" => …, ...}` (pass `:exec_seam` — caller already minted a session token) OR as a
  grant keyword list (`:exec`, mints a single token — for parity with `run_node/2`). Returns
  `{:ok, boot_js, token_or_nil}` (token is nil when a ready seam was supplied — the caller owns its lifetime).
  """
  def node_boot_payload(opts \\ []) do
    env = Keyword.get(opts, :env, %{})
    argv = Keyword.get(opts, :argv, ["node", "harness"])

    with {:ok, prelude} <- File.read(@node_prelude),
         {:ok, base_shims} <- load_node_shims() do
      {shims, exec_seam, token, _grant} =
        case {Keyword.get(opts, :exec_seam), Keyword.get(opts, :exec)} do
          {seam, _} when is_map(seam) ->
            # caller minted the (session-lived) token + seam already; add the child_process shim, and — when
            # the same token's grant carries a confined workdir — the SM fs shim too (resident-harness path).
            # The grant is bound into the host-import at instantiate time by HarnessSession, not here.
            workdir = fs_workdir!(Keyword.get(opts, :fs, []))

            base_shims
            |> register_exec_shims(true)
            |> register_fs_shim(workdir != nil)
            |> then(&{&1, seam, nil, nil})

          {nil, exec_opts} when is_list(exec_opts) ->
            maybe_grant_caps(base_shims, exec_opts, Keyword.get(opts, :fs))

          _ ->
            {base_shims, nil, nil, nil}
        end

      boot_seam =
        Jason.encode!(
          %{"shims" => shims, "env" => env, "argv" => argv}
          |> then(fn m -> if exec_seam, do: Map.put(m, "exec", exec_seam), else: m end)
        )

      {:ok, "globalThis.__wbNode=" <> boot_seam <> ";\n" <> prelude, token}
    end
  end

  # When exec and/or fs is granted, register the matching SM-lane shims, mint a SINGLE-run ExecLoopback token
  # carrying both grants, and build the boot seam {url, token}. Without any grant the capability shims aren't
  # registered → `require('child_process')`/`require('node:fs')` throw (no silent capability). One token, one
  # seam, both caps. The GRANT is returned too so it can be bound into the synchronous host-import (which the
  # shims prefer over the fetch loopback). Returns {shims, seam, token, grant}.
  defp maybe_grant_caps(shims, nil, nil), do: {shims, nil, nil, nil}

  defp maybe_grant_caps(shims, exec_opts, fs_opts) do
    exec_opts = exec_opts || []
    fs_opts = fs_opts || []

    allow = Keyword.get(exec_opts, :allow, false)
    workdir = fs_workdir!(fs_opts)

    # principal: an exec-capable grant must carry one (broker rate/concurrency/revoke handle); otherwise prefer
    # whichever opt list supplies it (fs ops are principal-revocable too).
    principal =
      if allow,
        do: require_principal!(true, exec_opts),
        else: Keyword.get(exec_opts, :principal) || Keyword.get(fs_opts, :principal)

    grant = %{
      allow: allow,
      commands: Keyword.get(exec_opts, :commands, :all),
      principal: principal,
      depth: Keyword.get(exec_opts, :depth, 0),
      # SLICE 3: per-(user, provider) creds scope for dock.creds.{get,put}.
      creds_scope: Keyword.get(exec_opts, :creds_scope, nil),
      # headless-JS path: the confined fs root. nil => every /__wb/fs op 403s (no fs reach).
      workdir: workdir
    }

    token = Workbooks.ExecLoopback.mint(grant)
    # best-effort loopback URL for the legacy fetch fallback; "" when the listener isn't running (host-import
    # deployments). The shims prefer __wbHostCall and never read this url under the host-import.
    seam = %{"url" => safe_sentinel_url() || "", "token" => token}

    shims =
      shims
      |> register_exec_shims(exec_opts != [])
      |> register_fs_shim(workdir != nil)

    {shims, seam, token, grant}
  end

  defp safe_sentinel_url do
    Workbooks.ExecLoopback.sentinel_url()
  rescue
    _ -> nil
  end

  # The exec/dock-auth shims (child_process over fetch + dock.creds/oauth). events is child_process's dep.
  defp register_exec_shims(shims, false), do: shims

  defp register_exec_shims(shims, true) do
    cp = File.read!(Path.join(@sm_shim_dir, "child_process.js"))
    events = Map.get(shims, "events") || File.read!(Path.join([@js_root, "shims", "events.js"]))
    dock_auth = File.read!(Path.join(@sm_shim_dir, "dock_auth.js"))
    shims |> Map.put("child_process", cp) |> Map.put("events", events) |> Map.put("dock-auth", dock_auth)
  end

  # The SM-lane fs shim (routes over fetch to /__wb/fs, confined to workdir) — supersedes the dead Javy fs
  # shim. Registered as both `fs` and `fs/promises` so `require('node:fs')` and `require('fs/promises')` hit it.
  defp register_fs_shim(shims, false), do: shims

  defp register_fs_shim(shims, true) do
    fs = File.read!(Path.join(@sm_shim_dir, "fs.js"))
    # `fs/promises` re-exports the shim's .promises — a tiny CJS re-export module.
    fs_promises = "module.exports = require('node:fs').promises;"
    shims |> Map.put("fs", fs) |> Map.put("fs/promises", fs_promises)
  end

  # Validate + expand the fs workdir from the fs grant opts. The directory is CREATED if missing (the caller's
  # confined scratch). Returns an absolute path, or nil when no fs grant was given.
  @doc false
  def fs_workdir!([]), do: nil

  def fs_workdir!(fs_opts) when is_list(fs_opts) do
    case Keyword.get(fs_opts, :workdir) do
      d when is_binary(d) and d != "" ->
        abs = Path.expand(d)
        File.mkdir_p!(abs)
        abs

      _ ->
        raise ArgumentError, "fs grant requires a non-empty :workdir (the confined host directory)"
    end
  end

  # FIX 1 (principal-OPTIONAL minting): an EXEC-CAPABLE harness grant (`allow: true`) MUST carry a non-nil
  # principal (the tenant/session id). The principal is what the broker rate-limits, concurrency-caps, and
  # revokes on — without it the loopback would hand ExecBroker a nil principal, which is the reserved
  # HOST-INTERNAL (uncapped, unrevocable) path, giving a granted harness UNCAPPED brokered exec. Refuse to
  # mint a principal-less exec grant here. (A non-exec grant — `allow: false` — never reaches this; its
  # principal is taken verbatim by maybe_grant_caps from whichever opt list supplies one.)
  defp require_principal!(true, exec_opts) do
    case Keyword.get(exec_opts, :principal) do
      p when is_binary(p) and p != "" ->
        p

      other ->
        raise ArgumentError,
              "exec-capable harness grant (allow: true) requires a non-nil :principal (the tenant/session id) — " <>
                "got #{inspect(other)}. nil-principal is reserved for trusted host-internal callers (e.g. JsDock " <>
                "direct calls), never the loopback."
    end
  end

  # Read each pure-JS Node shim into a name=>source map for the prelude's registry. Misses are skipped
  # (a builtin simply won't resolve) rather than failing the whole run.
  defp load_node_shims do
    shims =
      Enum.reduce(@node_builtins, %{}, fn name, acc ->
        path = Path.join([@js_root, "shims", name <> ".js"])

        case File.read(path) do
          {:ok, src} -> Map.put(acc, name, src)
          {:error, _} -> acc
        end
      end)

    {:ok, shims}
  end

  # ── ESM → CJS rewrite (headless-JS path) ───────────────────────────────────────────────────────
  #
  # The SM `run` bootstrap uses classic indirect eval, which rejects `import`/`export`/`import.meta`. Real
  # ESM bundles open with `import { createRequire } from 'module'; const require = createRequire(import.meta
  # .url)` (often ×3) + `import.meta.url`. This is a LINE-ORIENTED rewrite of the static module syntax into
  # CJS that the prelude's require/module system already serves — not a full parser, but it covers the shapes
  # a bundler emits (single-line static import/export statements). Dynamic `import()` is left untouched (SM
  # has it). A source with no ESM markers is returned byte-for-byte (the common CJS case is a no-op).
  def esm_to_cjs(src) when is_binary(src) do
    if Regex.match?(~r/^\s*(import|export)\s|import\.meta/m, src) do
      src
      |> String.replace(~r/\bimport\.meta\b/, "globalThis.__wbImportMeta")
      |> rewrite_lines()
    else
      src
    end
  end

  defp rewrite_lines(src) do
    src
    |> String.split("\n")
    |> Enum.map(&rewrite_line/1)
    |> Enum.join("\n")
  end

  # Each clause matches one static ESM statement and emits its CJS equivalent. Order matters (most specific
  # first). A line with no static import/export is returned unchanged.
  defp rewrite_line(line) do
    t = String.trim_trailing(line)

    cond do
      # import * as ns from 'mod'  ->  const ns = require('mod')
      m = Regex.run(~r/^\s*import\s+\*\s+as\s+(\w+)\s+from\s+["']([^"']+)["'];?\s*$/, t) ->
        [_, ns, mod] = m
        "const #{ns} = #{req(mod)};"

      # import def, { a, b as c } from 'mod'  ->  default + named
      m = Regex.run(~r/^\s*import\s+(\w+)\s*,\s*\{([^}]*)\}\s+from\s+["']([^"']+)["'];?\s*$/, t) ->
        [_, def, names, mod] = m
        tmp = tmpvar()
        "const #{tmp} = #{req(mod)}; const #{def} = (#{tmp} && #{tmp}.default !== undefined) ? #{tmp}.default : #{tmp}; const {#{cjs_names(names)}} = #{tmp};"

      # import { a, b as c } from 'mod'  ->  const { a, c: c } = require('mod')
      m = Regex.run(~r/^\s*import\s+\{([^}]*)\}\s+from\s+["']([^"']+)["'];?\s*$/, t) ->
        [_, names, mod] = m
        "const {#{cjs_names(names)}} = #{req(mod)};"

      # import def from 'mod'  ->  const def = require('mod').default ?? require('mod')
      m = Regex.run(~r/^\s*import\s+(\w+)\s+from\s+["']([^"']+)["'];?\s*$/, t) ->
        [_, def, mod] = m
        tmp = tmpvar()
        "const #{tmp} = #{req(mod)}; const #{def} = (#{tmp} && #{tmp}.default !== undefined) ? #{tmp}.default : #{tmp};"

      # import 'mod'  ->  require('mod')
      m = Regex.run(~r/^\s*import\s+["']([^"']+)["'];?\s*$/, t) ->
        [_, mod] = m
        "#{req(mod)};"

      # export default <expr>  ->  module.exports.default = <expr>
      m = Regex.run(~r/^\s*export\s+default\s+(.*)$/, t) ->
        [_, rest] = m
        "module.exports.default = #{rest}"

      # export { a, b as c }  ->  Object.assign(module.exports, { a: a, c: b })
      m = Regex.run(~r/^\s*export\s+\{([^}]*)\}\s*;?\s*$/, t) ->
        [_, names] = m
        "Object.assign(module.exports, {#{export_names(names)}});"

      # export const/let/var NAME = ...  ->  declare, then mirror onto exports
      m = Regex.run(~r/^\s*export\s+(const|let|var)\s+(\w+)\s*=\s*(.*)$/, t) ->
        [_, kw, name, rest] = m
        "#{kw} #{name} = #{rest}\nmodule.exports.#{name} = #{name};"

      # export function NAME(...)  /  export class NAME ...  ->  drop the `export ` keyword (decl is hoisted;
      # a trailing `module.exports.NAME = NAME` isn't emitted inline to keep the rewrite single-line-safe).
      m = Regex.run(~r/^\s*export\s+(async\s+function|function|class)\s+(\w+)(.*)$/, t) ->
        [_, kw, name, rest] = m
        "#{kw} #{name}#{rest}  /* wb-esm: module.exports.#{name} below */ ;globalThis.#{name}=globalThis.#{name};"

      true ->
        line
    end
  end

  # "a, b as c" -> "a, c: b"  (named-import rename in a destructuring pattern)
  defp cjs_names(names) do
    names
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn n ->
      case Regex.run(~r/^(\w+)\s+as\s+(\w+)$/, n) do
        [_, orig, as] -> "#{orig}: #{as}"
        _ -> n
      end
    end)
    |> Enum.join(", ")
  end

  # "a, b as c" -> "a: a, c: b"  (named-export: local b exported as c)
  defp export_names(names) do
    names
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn n ->
      case Regex.run(~r/^(\w+)\s+as\s+(\w+)$/, n) do
        [_, local, exported] -> "#{exported}: #{local}"
        _ -> "#{n}: #{n}"
      end
    end)
    |> Enum.join(", ")
  end

  defp q(s), do: ~s("#{s}")

  # Resolve a static import via the GLOBAL require — NOT a bare `require`, which a user `const require =
  # createRequire(import.meta.url)` later in the same block would shadow + TDZ-poison ("can't access lexical
  # declaration 'require' before initialization"). globalThis.require is always the prelude resolver.
  defp req(mod), do: "globalThis.require(#{q(mod)})"

  # A unique temp identifier per rewritten line so two desugared default-imports don't redeclare the same
  # `const` in one scope (which would be a hard SyntaxError).
  defp tmpvar, do: "__wbm#{:erlang.unique_integer([:positive])}"

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
