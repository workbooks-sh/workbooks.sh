defmodule Nexus.Porffor.Debug do
  @moduledoc """
  Durable observability for the **Porffor JS→WASM→Washy** lane.

  Debugging this lane used to mean ephemeral scripts + 600s reruns + ad-hoc instrumentation thrown away
  each time. This module makes it one call. `diagnose/2` compiles a JS program through Porffor (with the
  wasm "name" section, so every function is named), runs it on the Washy interpreter with a **bounded** fuel
  budget and **per-function call profiling**, then returns a structured report:

      %Nexus.Porffor.Debug.Report{
        output: "h1=<h1>Hello</h1>",          # what the guest printed
        error:  {:TypeError, "x is not a function"},  # decoded [ptr,type], or nil
        trap:   :out_of_bounds,               # Washy trap reason, or nil
        hot:    [{"__Porffor_malloc", 48547}, {"__TypeError_prototype_toString", 23127}, ...],
        elapsed_ms: 1200,
        completed: false
      }

  The `hot` list is the killer feature: a runaway loop or a trap localizes instantly to NAMED Porffor
  functions (a repeated `__TypeError_prototype_toString` = an exception thrown every iteration; a dominant
  `__Porffor_malloc` = runaway allocation), no recompile-with-`-d` dance, no guessing.

  CLI: `mix porffor.debug <file.js> [--fuel N] [--top N] [--transpile] [--prelude P]`.

  ## Methodology — how to debug the Porffor→Washy lane fast (read before grinding)

  The wall-clock killer is **serial guess-and-rerun**. The fixes that made this lane tractable:

  1. **MEASURE the assumption before fixing it.** Two "obvious" diagnoses this lane were both WRONG until
     measured: the "ASM-lane divergence/infinite-loop" was ordinary regex/codegen bugs (not an ASM-specific
     problem — it failed on interp too); and the marked "table needs no-GC memory" was a −2000 negative
     pointer (raising the memory cap 256MB→3GB changed nothing). One cheap measurement each killed a
     would-be multi-day rewrite. Never fix a layer until a measurement points at it.

  2. **Bisect with the corpus, not one case at a time.** Run a whole package's feature corpus, collect ALL
     failures in one pass (per-case = fresh wasm instance, since many parses in one instance hit the no-GC
     ceiling), then fix in batches. `run_corpus.exs` (CASE=<i> LANE=ASM|interp) is the harness.

  3. **Reproduce minimally, off the real artifact.** When a feature fails inside marked, lift the exact
     sub-expression (the regex, the `var` decl, the `splitCells` body) into a 5-line repro and diff washy vs
     `node`. Most bugs are general JS-semantics gaps (var-declarator zero-init, char-class byte-truncation,
     RegExp.lastIndex setter) that repro in isolation — and the fix then helps every package, not just marked.

  4. **Two lanes, both required, but pick the right one to debug on.** interp (`transpile: false`) is the
     oracle; the ASM transpiler (`transpile: true`) is what ships. They diverge in exactly one known way —
     `Sandbox.run_command` PREWARMS (eager transpile) and miscompiles (drops chars, G5); the LAZY transpile
     path this tool uses is correct. So debug + assert via this tool, never `Sandbox.run_command`.

  5. **Instrument Washy, gated.** `Process.put(:washy_oob_debug, true)` prints `{addr, n, limit, pages}` on
     every out-of-bounds — an `addr` near 2^32 is a wrapped negative pointer (a bad index), not memory
     exhaustion. `Process.put(:washy_callcount_on, true)` + `:washy_callcount` powers the named hot profile.
     Both are gated and cost nothing when off.

  The loop is: corpus → pick a failure → `diagnose` for the named function + decoded error/trap → if OOB,
  flip `:washy_oob_debug` for the address → minimal repro → fix the general gap → regen builtins → re-corpus.
  """

  alias Nexus.Compilers.Js.Porffor

  defmodule Report do
    @moduledoc false
    defstruct output: "", error: nil, trap: nil, hot: [], elapsed_ms: 0, completed: false, wasm_bytes: 0
  end

  # Porffor internal error type ids (registration order in compiler/types.js: '', Aggregate, Type,
  # Reference, Syntax, Range, Eval, URI, Test262 → "<x>Error"). Empirically Error=36 (TypeError=38,
  # ReferenceError=39). Used to name a thrown [ptr, type] pair.
  @error_types %{
    36 => :Error,
    37 => :AggregateError,
    38 => :TypeError,
    39 => :ReferenceError,
    40 => :SyntaxError,
    41 => :RangeError,
    42 => :EvalError,
    43 => :URIError,
    44 => :Test262Error
  }

  @default_fuel 2_000_000_000

  @doc """
  Compile + run `js` through the Porffor→Washy lane under a fuel cap, returning a `%Report{}`.

  Opts: `:fuel` (instruction budget, default #{@default_fuel}), `:top` (hot funcs to keep, default 25),
  `:entry` (exported function, default `"m"`), `:transpile` (asm lane, default false — pure interp gives
  the cleanest profile), `:root` (compiler root).
  """
  def diagnose(js, opts \\ []) when is_binary(js) do
    fuel = Keyword.get(opts, :fuel, @default_fuel)
    top = Keyword.get(opts, :top, 25)
    entry = Keyword.get(opts, :entry, "m")
    transpile = Keyword.get(opts, :transpile, false)
    max_pages = Keyword.get(opts, :max_pages)
    root = Keyword.get(opts, :root, Nexus.Compilers.Shared.default_root())

    with {:ok, wasm} <- Porffor.compile(js, root, debug: true),
         {:ok, mod} <- Nexus.Washy.decode_cached(wasm) do
      run(mod, byte_size(wasm), fuel, top, entry, transpile, max_pages)
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp run(mod, wasm_bytes, fuel, top, entry, transpile, max_pages \\ nil) do
    call_opts = [transpile: transpile, fuel: fuel] ++ if(max_pages, do: [max_pages: max_pages], else: [])
    out_append = fn s -> Process.put(:washy_out, [s | Process.get(:washy_out, [])]) end

    Process.put(:washy_imports, %{
      "a" => fn [v] -> out_append.(num_to_string(v)); nil end,
      "b" => fn [v] -> out_append.(<<trunc(v)::utf8>>); nil end,
      "c" => fn [] -> 0.0 end,
      "d" => fn [] -> 0.0 end,
      "e" => &Nexus.Compilers.Js.PorfforHost.host_call/1
    })

    Process.put(:washy_backend, :map)
    Process.put(:washy_fds, %{})
    Process.put(:washy_nextfd, 4)
    Process.put(:washy_callcount_on, true)
    Process.put(:washy_callcount, %{})

    t0 = System.monotonic_time(:millisecond)

    {completed, error, trap, ok_out} =
      try do
        # call_io captures stdout and RETURNS it (then restores the prior :washy_out), so use the return on
        # success. On a throw it does NOT restore, so the catch reads the live dict instead.
        {_res, io} = Nexus.Washy.call_io(mod, entry, [], call_opts)
        {true, nil, nil, IO.iodata_to_binary(io)}
      catch
        _, %Nexus.Washy.Trap{reason: reason} -> {false, nil, reason, nil}
        _, {:wasm_exc, _, [ptr, type]} when is_number(ptr) -> {false, decode_error(type, ptr), nil, nil}
        _, other -> {false, {:caught, inspect(other, limit: 5)}, nil, nil}
      end

    elapsed = System.monotonic_time(:millisecond) - t0

    output =
      ok_out || (Process.get(:washy_out, []) |> Enum.reverse() |> IO.iodata_to_binary())

    Process.delete(:washy_callcount_on)

    hot =
      Process.get(:washy_callcount, %{})
      |> Enum.sort_by(fn {_, n} -> -n end)
      |> Enum.take(top)
      |> Enum.map(fn {key, n} ->
        {kind, idx} = case key do {:ind, f} -> {:indirect, f}; f -> {:direct, f} end
        name = Map.get(mod.func_names, idx, "func##{idx}")
        %{name: name, calls: n, index: idx, kind: kind}
      end)

    {:ok,
     %Report{
       output: output,
       error: error,
       trap: trap,
       hot: hot,
       elapsed_ms: elapsed,
       completed: completed,
       wasm_bytes: wasm_bytes
     }}
  end

  # A thrown Porffor error is `[ptr, type]`; the message string lives at `load_i32(ptr) -> msgptr`, then a
  # bytestring `<len::i32><bytes>` at msgptr. Memory survives the throw in `:washy_mem` (not restored on a
  # raised exception), so we can read it here.
  defp decode_error(type, ptr) do
    mem = Process.get(:washy_mem)
    name = Map.get(@error_types, trunc(type), :"type#{trunc(type)}")

    msg =
      try do
        msgptr = u32(mem, trunc(ptr))
        len = u32(mem, msgptr)
        Nexus.Washy.read_bytes(mem, msgptr + 4, min(len, 500))
      rescue
        _ -> "<unreadable>"
      end

    {name, msg}
  end

  defp u32(mem, addr) do
    <<v::little-32>> = Nexus.Washy.read_bytes(mem, addr, 4)
    v
  end

  # Porffor prints numbers via the host `print` import; mirror Sandbox's integer-vs-float formatting.
  defp num_to_string(v) when is_integer(v), do: Integer.to_string(v)
  defp num_to_string(v) when is_float(v) do
    if v == Float.round(v) and abs(v) < 1.0e15, do: Integer.to_string(trunc(v)), else: Float.to_string(v)
  end

  defp num_to_string(v), do: to_string(v)

  @doc "Pretty one-line-per-row report for the CLI / IEx."
  def format(%Report{} = r) do
    status =
      cond do
        r.completed -> "COMPLETED"
        r.trap -> "TRAP #{r.trap}"
        r.error -> "THREW #{inspect(r.error)}"
        true -> "STOPPED"
      end

    head =
      "#{status} in #{r.elapsed_ms}ms  (wasm #{div(r.wasm_bytes, 1024)}KB)\n" <>
        "output: #{inspect(r.output)}\n" <>
        "--- hot functions (name : calls) ---"

    rows =
      r.hot
      |> Enum.map(fn h ->
        k = if h.kind == :indirect, do: "*", else: " "
        "#{k} #{String.pad_trailing(h.name, 42)} #{h.calls}"
      end)
      |> Enum.join("\n")

    head <> "\n" <> rows
  end
end
