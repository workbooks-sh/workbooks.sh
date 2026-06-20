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

  @doc """
  Evaluate `src` (modern JS) → `{:ok, string} | {:error, reason}`.

    * `opts[:timeout]` — ms (default 15s)
    * `opts[:imports]` — host functions the eval-host's WIT world imports, in `Wasmex.Components`
      shape (`%{"name" => {:fn, fun}}`). The toolkit capability bridge passes `Nexus.Toolkit.Caps`
      impls here (only meaningful once the eval-host is rebuilt to declare the cap import interface;
      a plain eval-host ignores an empty map).
  """
  def eval(src, opts \\ []) when is_binary(src) do
    timeout = Keyword.get(opts, :timeout, 15_000)
    imports = Keyword.get(opts, :imports, %{})

    cfg =
      %{path: wasm(), wasi: %Wasmex.Wasi.WasiP2Options{allow_http: true}}
      |> maybe_put_imports(imports)

    case Wasmex.Components.start_link(cfg) do
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

  defp maybe_put_imports(cfg, imports) when map_size(imports) == 0, do: cfg
  defp maybe_put_imports(cfg, imports), do: Map.put(cfg, :imports, imports)

  @doc "Whether the StarlingMonkey engine wasm is present."
  def available?, do: File.exists?(wasm())

  defp wasm, do: Application.get_env(:nexus, :js_engine_wasm, Path.join([File.cwd!(), "priv", "eval-host.wasm"]))
end
