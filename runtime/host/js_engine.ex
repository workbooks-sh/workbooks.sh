defmodule Workbooks.JsEngine do
  @moduledoc """
  FULL JavaScript engine in-sandbox — StarlingMonkey (SpiderMonkey compiled to wasm) as a runtime EVAL host.

  Spec-complete ECMAScript + fetch/streams/TextEncoder/Web APIs, running ENTIRELY inside wasmtime: no V8, no
  native code generation (W^X-safe — SpiderMonkey ships a portable bytecode interpreter, not a JIT), no microVM.
  This is the full-JS-language upgrade over the QuickJS lane (which is ES2020-ish + partial). The engine artifact
  (`@bytecodealliance/componentize-js`'s StarlingMonkey, ~10MB) is already vendored in node_modules.

  HOW IT WORKS (the unlock): we componentize ONE fixed `run(src)` bootstrap that `eval`s its argument — a FIXED
  host asset built once via jco/StarlingMonkey (the only build-time native step, like the compilers) and cached.
  Then ARBITRARY user JS is fed at RUNTIME as the call argument — no rebuild per program. Componentize-at-build
  was always fine; the "fm0.7 blocker" was only ever about generating typed components at build time, never
  about running JS.

  BROKERED CAPS: the guest's `fetch()` lowers to `wasi:http/outgoing-handler` -> the vendored
  `WasiHttpView::send_request` override -> NetGuard (SSRF + resolve-then-pin + net_allow scope), exactly like
  every other Instance. So evaled JS gets SSRF-safe brokered networking for free. (Proven for StarlingMonkey
  guests by test/broker_net_e2e_test.exs.)

  weval `--aot` (a one-time engine specialization, also already vendored as `starlingmonkey_embedding_weval.wasm`)
  is a later drop-in speed flag; v1 ships the interpreter (correctness + full API surface is the win).

  ── STATUS: SCAFFOLD, blocked on a WASI version skew (verified 2026-06-13) ───────────────────────────────────
  `build_host/0` WORKS — jco componentizes the bootstrap into a 12.5MB StarlingMonkey eval-host. But
  instantiation FAILS: the current componentize-js StarlingMonkey embedding hard-imports `wasi:http/types@0.2.10`
  (and io/streams etc.) EVEN WITH `--disable http` (StarlingMonkey hard-links wasi:http/io — see instance.ex),
  while our vendored wasmtime 39 / patched wasmex advertises wasi 0.2.0/0.2.3/0.2.6. Error:
    `component imports instance wasi:http/types@0.2.10, but a matching implementation was not found in the linker`.
  RESOLUTION (the one real task between us and the full JS universe): bump the vendored wasmex
  (vendor/wasmex/native/wasmex) to provide wasi:http@0.2.10 (+ the 0.2.10 io/streams/cli) in its linker and
  rebuild the NIF — OR obtain/produce a StarlingMonkey embedding targeting our wasi version. M–L effort, isolated
  to the vendored NIF. Once the linker matches, this module's `eval/2` works as written (the bootstrap + the
  brokered-fetch path are already correct). Tracked as a bead; do NOT mark any JS item "live" via this until
  `eval("6*7") == {:ok, "42"}` passes a real test.
  """
  require Logger

  @root Path.expand(Path.join(__DIR__, ".."))
  @cache Path.join(@root, "build/jsengine")
  @wit Path.join(@root, "wit/jsworkbook.wit")
  @host Path.join(@cache, "eval-host.component.wasm")

  # the fixed eval bootstrap — exports the workbook world's `run(input)`, eval's the JS, returns a string.
  @bootstrap ~S"""
  export function run(src) {
    try {
      const r = (0, eval)(src);
      if (r === undefined) return "undefined";
      if (typeof r === "object" && r !== null) {
        try { return JSON.stringify(r); } catch (_) { return String(r); }
      }
      return String(r);
    } catch (e) {
      return "ERR: " + (e && e.message ? e.message : String(e));
    }
  }
  """

  @doc """
  Build the eval-host component once (jco/StarlingMonkey, cached). Returns `{:ok, wasm_path}` | `{:error, why}`.
  `http`/`random`/`clocks` are enabled so evaled JS can use fetch + Web APIs (fetch is SSRF-brokered).
  """
  def build_host do
    if File.exists?(@host) do
      {:ok, @host}
    else
      Workbooks.Tools.ensure_jco!()
      File.mkdir_p!(@cache)
      js = Path.join(@cache, "eval-host.js")
      File.write!(js, @bootstrap)

      args =
        [
          "node_modules/.bin/jco", "componentize", Path.relative_to(js, @root),
          "--wit", Path.relative_to(@wit, @root), "--world-name", "workbook",
          "--enable", "http", "--enable", "random", "--enable", "clocks",
          "-o", Path.relative_to(@host, @root)
        ]

      case System.cmd("node", args, cd: @root, stderr_to_stdout: true) do
        {_, 0} -> {:ok, @host}
        {err, _} -> {:error, {:componentize_failed, String.slice(err, 0, 400)}}
      end
    end
  end

  @doc """
  Evaluate JS `src` in a fresh full-SpiderMonkey instance; returns `{:ok, result_string}` | `{:error, why}`.
  The result is the last expression coerced to a string (objects -> JSON). opts:
    * `:allow_http` (default false) — let evaled JS `fetch()` (routes through NetGuard, SSRF-safe)
    * `:timeout` (ms, default 12_000)
  """
  def eval(src, opts \\ []) when is_binary(src) do
    allow_http = Keyword.get(opts, :allow_http, false)
    timeout = Keyword.get(opts, :timeout, 12_000)

    with {:ok, host} <- build_host() do
      case Wasmex.Components.start_link(%{
             path: host,
             wasi: %Wasmex.Wasi.WasiP2Options{allow_http: allow_http}
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
end
