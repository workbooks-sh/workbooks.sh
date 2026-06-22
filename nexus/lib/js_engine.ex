defmodule Nexus.JsEngine do
  @moduledoc """
  Real JavaScript in the sandbox — **StarlingMonkey** (SpiderMonkey compiled to wasm) as an eval host,
  run via `Wasmex.Components` in wasmtime. Full modern ECMAScript + the WHATWG platform (WebCrypto,
  `fetch`/wasi:http, web streams, TextEncoder) and a real **event loop** (Promises/async settle) — the
  things Boa lacks. This is the engine for the browser greenfield: a JS DOM (linkedom/happy-dom) + a
  page's framework JS run here, with layout delegated to the in-wasm Blitz renderer.

  `eval/2` evaluates a JS string and returns the last expression coerced to a string. The engine wasm
  (~11MB, the componentize-js / StarlingMonkey eval-host) is staged in `priv/` (gitignored, rebuildable).
  """

  # The single synchronous host-broker seam the eval-host imports (bound to globalThis.__wbHostCall).
  # Matches the workbook WIT world: `package wb:jseval; interface broker { host-call: func(req)->string }`.
  @broker_ns "wb:jseval/broker"
  @broker_fn "host-call"

  @doc "The host-broker import namespace + function the eval-host imports."
  def broker_seam, do: {@broker_ns, @broker_fn}

  @doc """
  Evaluate `src` (modern JS) → `{:ok, string} | {:error, reason}`.

    * `opts[:timeout]` — ms (default 15s)
    * `opts[:broker]` — the `host-call` closure, a 1-arg `(req_json) -> resp_json` fn the eval-host's
      `wb:jseval/broker.host-call` import resolves to (reachable from guest JS as `__wbHostCall`). The
      toolkit lane passes `Nexus.Toolkit.Caps.broker/2` (path-scoped, grant-filtered). Default DENIES
      every op, so a plain eval (e.g. js_dom) instantiates with no capability surface.
  """
  def eval(src, opts \\ []) when is_binary(src) do
    timeout = Keyword.get(opts, :timeout, 15_000)
    broker = Keyword.get(opts, :broker, &deny_broker/1)
    imports = %{@broker_ns => %{@broker_fn => {:fn, broker}}}

    # Same untrusted-guest protections as Nexus.Sandbox: a per-guest memory ceiling (so a runaway
    # eval can't OOM the nexus) and a per-call epoch deadline (so a spinning eval traps and frees its
    # thread) — the store is built on the shared epoch engine with StoreLimits applied.
    wasi = %Wasmex.Wasi.WasiP2Options{allow_http: true}
    epoch_secs = Nexus.Config.sandbox_epoch_secs()

    with {:ok, store} <-
           Wasmex.Components.Store.new_wasi(wasi, Nexus.Sandbox.store_limits(), Nexus.Sandbox.epoch_engine()) do
      cfg = %{path: wasm(), imports: imports, store: store}

      case Wasmex.Components.start_link(cfg) do
        {:ok, pid} ->
          try do
            Wasmex.Components.call_function(pid, "run", [src], timeout, epoch_secs)
          after
            if Process.alive?(pid), do: Process.exit(pid, :normal)
          end

        {:error, reason} ->
          {:error, {:instantiate_failed, reason}}
      end
    else
      {:error, reason} -> {:error, {:store_failed, reason}}
    end
  end

  # No capability granted on this eval: every op default-denies (plain evals / js_dom get no surface).
  defp deny_broker(_req_json), do: ~s({"ok":false,"error":"no capability granted"})

  @doc "Whether the StarlingMonkey engine wasm is present."
  def available?, do: File.exists?(wasm())

  defp wasm, do: Application.get_env(:nexus, :js_engine_wasm, Path.join([File.cwd!(), "priv", "eval-host.wasm"]))
end
