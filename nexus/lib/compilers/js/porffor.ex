defmodule Nexus.Compilers.Js.Porffor do
  @moduledoc """
  **The Porffor JS→wasm fast lane — one layer, no inner interpreter.**

  Porffor (https://porffor.dev, MIT, vendored at `compilers/js/porffor/`) is an ahead-of-time JS/TS→wasm
  compiler: it compiles the program *itself* to a tiny wasm module, instead of shipping a JS engine that
  interprets it. Run on Washy's transpiler lane that is **near-native** — measured ~2500× faster than the
  same JS through quickjs-on-Washy on the AOT-friendly subset.

  Porffor compiles a **static subset** of JS (no `eval`/`new Function`; closures/async/generators/regex and
  swaths of stdlib are partial — see the gap census). A hard compile failure ⇒ `{:error, :unsupported}`.
  Silent miscompiles (wrong runtime output for a buggy feature) are NOT caught here — they're caught by the
  conformance harness that diffs Porffor output against an oracle during fork development.

  ## Module shape (differs from the quickjs WASI command module)
  Porffor output is **not** WASI: no `_start`, no `fd_write`. It exports the program top level as function
  **`m`** and imports its host I/O as single-char names assigned by `createImport` order
  (`String.fromCharCode(97 + index)`, builtins.js): **`a`=print(number), `b`=printChar(charcode),
  `c`=time, `d`=timeOrigin**. `run/2` provides these on Washy, captures `print`/`printChar` into the
  stdout buffer, and invokes `m`.
  """
  require Logger

  # Porffor's host imports, by their fixed single-char wasm name (createImport order). Only the USED ones
  # are emitted per program; providing all is harmless (Washy only calls imported funcs).
  @print "a"
  @print_char "b"
  @time "c"
  @time_origin "d"

  @doc "Path to the vendored Porffor `porf` CLI entrypoint."
  def porf_entry(root \\ Nexus.Compilers.Shared.default_root()),
    do: Path.expand(Path.join([root, "js", "porffor", "runtime", "index.js"]))

  @doc """
  Compile JS source → `{:ok, wasm_bytes}` or `{:error, :unsupported}`. Shells the vendored Porffor on the
  host's Node (build-time/trusted — the *output* wasm is what runs untrusted on Washy). Any Porffor failure
  (parse error, unsupported feature, link gap, empty output) classifies as `:unsupported` so the caller can
  decide; never a hard crash.
  """
  def compile(source, root \\ Nexus.Compilers.Shared.default_root()) when is_binary(source) do
    entry = porf_entry(root)

    if not File.regular?(entry) do
      {:error, {:porffor_missing, entry}}
    else
      work = Path.join(System.tmp_dir!(), "nxc_porf_#{System.unique_integer([:positive])}")
      Nexus.Paths.mkdir_private!(work)
      in_js = Path.join(work, "in.js")
      out_wasm = Path.join(work, "out.wasm")
      File.write!(in_js, source)

      try do
        case System.cmd("node", [entry, "wasm", in_js, out_wasm], stderr_to_stdout: true) do
          {_out, 0} ->
            if File.regular?(out_wasm) and File.stat!(out_wasm).size > 0,
              do: {:ok, File.read!(out_wasm)},
              else: {:error, :unsupported}

          {out, _code} ->
            Logger.debug("porffor: unsupported — #{String.slice(out, 0, 200)}")
            {:error, :unsupported}
        end
      rescue
        e -> Logger.debug("porffor: invoke failed — #{Exception.message(e)}"); {:error, :unsupported}
      after
        File.rm_rf(work)
      end
    end
  end

  @doc """
  Run a Porffor wasm module on Washy (transpiler lane), returning `{:ok, stdout}`. Provides the print/
  printChar/time imports and invokes the exported `m`. Runs in an isolated task (per-run process dict).
  """
  def run(wasm_bytes, opts \\ []) when is_binary(wasm_bytes) do
    task =
      Task.async(fn ->
        case Nexus.Washy.decode(wasm_bytes) do
          {:ok, mod} ->
            Process.put(:porffor_out, [])
            emit = fn s -> Process.put(:porffor_out, [s | Process.get(:porffor_out, [])]) end

            imports = %{
              @print => fn [v] -> emit.(num_to_string(v)); nil end,
              @print_char => fn [v] -> emit.(<<trunc(v)::utf8>>); nil end,
              @time => fn [] -> 0.0 end,
              @time_origin => fn [] -> 0.0 end
            }

            Process.put(:washy_imports, imports)

            transpile? = Keyword.get(opts, :transpile, true)

            case Nexus.Washy.instance_start(mod, "m", [], transpile: transpile?) do
              {:ok, _inst, _} ->
                {:ok, Process.get(:porffor_out, []) |> Enum.reverse() |> IO.iodata_to_binary()}

              other ->
                {:error, {:porffor_run, other}}
            end

          err ->
            err
        end
      end)

    Task.await(task, Keyword.get(opts, :timeout_ms, 120_000))
  end

  @doc "Compile + run in one step: JS source → `{:ok, stdout}` | `{:error, :unsupported | reason}`."
  def eval(source, opts \\ []) do
    case compile(source) do
      {:ok, wasm} -> run(wasm, opts)
      err -> err
    end
  end

  # JS Number#toString for the f64 Porffor hands to `print`. Whole numbers render without a decimal
  # (999000.0 → "999000"); fractional via Elixir's shortest float repr. (Not yet full ECMAScript
  # ToString — Grisu/shortest-round-trip edge cases are a known gap, tracked for the conformance pass.)
  defp num_to_string(v) when is_float(v) do
    if v == Float.round(v) and abs(v) < 9.007199254740992e15,
      do: Integer.to_string(trunc(v)),
      else: Float.to_string(v)
  end

  defp num_to_string(v), do: to_string(v)
end
