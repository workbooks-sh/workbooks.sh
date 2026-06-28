defmodule Nexus.Washy.Sandbox do
  @moduledoc """
  The **bounded run harness** for untrusted wasm — the one entry point production uses to execute a
  guest. It wraps `Nexus.Washy.call_io/4` in a fresh, isolated, time-bounded process so a hostile or
  buggy module cannot harm the host:

    * **wall-clock** — the guest runs in a `Task`; past `:timeout_ms` it is `:brutal_kill`ed → `{:timeout}`.
    * **fuel / call-depth / memory** — bounded by the interpreter itself (atomics counters → traps;
      memory capped at the allocation). Passed through via opts.
    * **process isolation** — the guest runs in its OWN process; a trap or crash stays there, the
      caller (and the VM) survive. This is the BEAM isolation thesis as an API.
    * **output cap** — captured stdout is truncated at `:max_output` bytes (`truncated?: true`).

  Returns one of:
    `{:ok, result, stdout, meta}` · `{:trap, reason}` · `{:exit, code, stdout}` · `{:timeout}` · `{:error, term}`

  Per-run context (VFS backend, argv, stdin) is snapshotted from the caller's process dict and replanted
  into the run process, so existing call sites keep working unchanged.
  """
  alias Nexus.Washy
  alias Nexus.Washy.Trap

  @default_timeout_ms 30_000
  @default_max_output 16 * 1024 * 1024
  # interp TERM-heap ceiling (words) for one guest run — ~2 GB. `:max_heap_size` does NOT count the
  # off-heap `:atomics` linear memory; this bounds only the interpreter's Elixir term state, whose
  # heavy-run high-water measured ~1.5 MB — so it never false-kills a real run, it just turns a runaway
  # interp heap into one killed run instead of a VM-wide OOM. Tune via `opts[:max_heap_words]`.
  @default_run_heap_words 268_435_456

  # process-dict keys that carry per-run guest context across into the isolated run process
  @ctx_keys [:washy_vfs, :washy_fds, :washy_nextfd, :washy_argv, :washy_stdin, :washy_backend, :washy_clock, :washy_out,
             # Beam.* interop context: a guest-actor re-entry carries its self handle + the delivered
             # message (inbox) into the run Task so beam_self/beam_recv resolve inside the guest.
             :washy_actor_self, :washy_actor_from, :washy_beam_inbox,
             # registrable host-import table — carries the Porffor print/printChar/time shims (and any
             # other host imports) into the isolated run Task.
             :washy_imports]

  @doc """
  Run exported `name(args)` of `mod` under all bounds. Opts: `:timeout_ms` (default #{@default_timeout_ms}),
  `:max_output` (default #{@default_max_output}), plus interpreter bounds `:fuel` / `:max_depth`.
  """
  def run(%Washy{} = mod, name, args, opts \\ []) when is_list(args) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    max_out = Keyword.get(opts, :max_output, @default_max_output)

    # validate untrusted structure up front (default on); reject malformed before spending a process
    case if(Keyword.get(opts, :validate, true), do: Nexus.Washy.Validate.validate(mod), else: :ok) do
      {:error, reason} -> {:error, reason}
      :ok -> do_run(mod, name, args, opts, timeout, max_out)
    end
  end

  # The guest runs in a fresh process that is UNLINKED + monitored + heap-bounded (mirrors the compile
  # worker in `Transpile.compile_bounded`). It is deliberately NOT a plain `Task.async`:
  #   * a `:max_heap_size` kill on a LINKED task propagates the `:killed` exit through the link and
  #     takes the CALLER down with it (verified) — an unlinked monitor contains it as `{:DOWN, …}`.
  #   * a fault inside the run is already caught and returned as a value, so the process exits `:normal`
  #     on the happy/handled paths; the `{:DOWN, …}` arm fires only for the heap-cap kill (or another
  #     unforeseen abnormal death), and stays contained — the caller and the VM survive either way.
  defp do_run(mod, name, args, opts, timeout, max_out) do
    ctx = Map.new(@ctx_keys, fn k -> {k, Process.get(k)} end)
    heap_words = Keyword.get(opts, :max_heap_words, @default_run_heap_words)
    parent = self()
    ref = make_ref()

    {pid, mon} =
      :erlang.spawn_opt(
        fn ->
          Enum.each(ctx, fn {k, v} -> if v != nil, do: Process.put(k, v) end)

          result =
            try do
              {res, out} = Washy.call_io(mod, name, args, opts)
              {:ok, res, out}
            rescue
              e in Trap -> {:trap, e.reason}
              # ANY other exception (e.g. an unvalidated module hitting a bad index) is contained here,
              # never propagated to the caller — the run process owns the fault.
              e -> {:error, Exception.message(e)}
            catch
              :throw, {:washy_exit, code} ->
                out = Process.get(:washy_out, []) |> Enum.reverse() |> IO.iodata_to_binary()
                {:exit, code, out}

              kind, reason ->
                {:error, {kind, reason}}
            end

          send(parent, {ref, result})
        end,
        [:monitor, {:max_heap_size, %{size: heap_words, kill: true, error_logger: false}}]
      )

    receive do
      {^ref, result} ->
        Process.demonitor(mon, [:flush])

        case result do
          {:ok, res, out} ->
            {clipped, trunc?} = clip(out, max_out)
            {:ok, res, clipped, %{truncated?: trunc?}}

          {:exit, code, out} ->
            {clipped, _} = clip(out, max_out)
            {:exit, code, clipped}

          {:trap, reason} ->
            {:trap, reason}

          {:error, reason} ->
            {:error, reason}
        end

      {:DOWN, ^mon, _, _, reason} ->
        # abnormal death (the heap-cap kill, or anything unforeseen) — contained; the caller lives
        {:error, {:run_killed, reason}}
    after
      timeout ->
        Process.exit(pid, :kill)
        Process.demonitor(mon, [:flush])
        {:timeout}
    end
  end

  defp clip(bin, max) when byte_size(bin) <= max, do: {bin, false}
  defp clip(bin, max), do: {binary_part(bin, 0, max), true}

  @doc """
  Run a **WASI command module** (stdin → stdout) on Washy — the in-process replacement for
  `Nexus.Sandbox.run_command` (the wasmtime subprocess lane). Handles both shapes:

    * `wasm` (binary) — a self-contained command module (js/ts, a toolkit CLI): `_start`, fed `stdin`.
    * `{:interp, interp_wasm, source}` — an interpreter + its script (python): the source is placed in
      the VFS and the interpreter runs it.

  Returns `{:ok, stdout} | {:error, reason}`. Bounded + BEAM-isolated like every Washy run. Opts:
  `:vfs` (initial files), `:argv`, plus the standard per-run bounds.
  """
  def run_command(spec, stdin \\ "", opts \\ [])

  def run_command(wasm, stdin, opts) when is_binary(wasm) do
    case Nexus.Washy.decode_cached(bytes(wasm)) do
      {:ok, mod} ->
        if porffor_module?(mod),
          do: exec_porffor(mod, opts),
          else: exec_module(mod, Keyword.get(opts, :argv, ["cmd"]), stdin, Keyword.get(opts, :vfs, %{}), opts)

      err ->
        err
    end
  end

  # A Porffor JS→wasm module is NOT a WASI command: it has no `_start`, exports the program top level as
  # `m`, and emits its own host I/O imports (print/printChar). Detect to route it to the Porffor run path.
  defp porffor_module?(mod),
    do: Map.has_key?(mod.exports, "m") and not Map.has_key?(mod.exports, "_start")

  # Run a Porffor module: provide its host imports (single-char names by createImport order — a=print,
  # b=printChar, c=time, d=timeOrigin) writing into the stdout buffer, then invoke `m` (which also drains
  # the async microtask queue at its end). Same isolation/bounds as exec_module.
  defp exec_porffor(mod, opts) do
    out_append = fn s -> Process.put(:washy_out, [s | Process.get(:washy_out, [])]) end

    Process.put(:washy_imports, %{
      "a" => fn [v] -> out_append.(porf_num(v)); nil end,
      "b" => fn [v] -> out_append.(<<trunc(v)::utf8>>); nil end,
      "c" => fn [] -> 0.0 end,
      "d" => fn [] -> 0.0 end,
      "e" => &Nexus.Compilers.Js.PorfforHost.host_call/1
    })

    Process.put(:washy_backend, :map)
    Process.put(:washy_fds, %{})
    Process.put(:washy_nextfd, 4)

    # PREWARM Porffor modules (re-enabled, wb-sc0m). The asm + forms lanes are now multi-value-aware — a
    # function returning Porffor's [value,type] pair lowers to a TOP-FIRST result list (== interp
    # `interp_invoke`), which `push_results/3` splices consistently across the asm↔interp boundary. So a
    # small single-purpose JS program goes native from call 1 (compile cached cross-run), bit-identical to
    # interp; modules over @prewarm_func_cap skip and stay lazy/interp. The earlier push_results crash is
    # fixed at its root, not by skipping prewarm.
    transpile? = Keyword.get(opts, :transpile, true)
    # asm_only? = true: Porffor is f64-heavy and the abstract-forms lane has a pre-existing f64-global
    # miscompile, so prewarm only via the bit-identical asm lane; asm-unsupported funcs stay interpreted.
    if transpile?, do: Nexus.Washy.Transpile.prewarm_bounded(mod, "m", true)

    case run(mod, "m", [], Keyword.put(opts, :transpile, transpile?)) do
      {:ok, _r, out, _meta} -> {:ok, out}
      {:exit, _code, out} -> {:ok, out}
      {:trap, reason} -> {:error, {:trap, reason}}
      {:timeout} -> {:error, :timeout}
      {:error, e} -> {:error, e}
    end
  end

  # JS Number#toString for the f64 Porffor hands `print`: non-finite → NaN/Infinity; whole → no decimal.
  defp porf_num({:nonfinite, bits, _}) do
    cond do
      bits == 0x7FF0000000000000 -> "Infinity"
      bits == 0xFFF0000000000000 -> "-Infinity"
      true -> "NaN"
    end
  end

  defp porf_num(v) when is_float(v) do
    if v == Float.round(v) and abs(v) < 9.007199254740992e15,
      do: Integer.to_string(trunc(v)),
      else: Float.to_string(v)
  end

  defp porf_num(v), do: to_string(v)

  def run_command({:interp, interp, source}, stdin, opts) do
    case Nexus.Washy.decode_cached(bytes(interp)) do
      {:ok, mod} ->
        vfs = Map.put(Keyword.get(opts, :vfs, %{}), "main", source)
        exec_module(mod, Keyword.get(opts, :argv, ["interp", "/work/main"]), stdin, vfs, opts)

      err ->
        err
    end
  end

  # the compiler lanes hand us a PATH to the built wasm (js/python interpreters); accept bytes too
  defp bytes(b) when is_binary(b), do: if(File.regular?(b), do: File.read!(b), else: b)

  defp exec_module(mod, argv, stdin, vfs, opts) do
    # set the per-run context the Sandbox snapshots into its isolated Task
    Process.put(:washy_stdin, stdin)
    Process.put(:washy_argv, argv)
    Process.put(:washy_vfs, vfs)
    Process.put(:washy_backend, :map)
    Process.put(:washy_fds, %{})
    Process.put(:washy_nextfd, 4)

    # tiered transpilation (native-compile hot functions; cached per module). Neutral mechanism, on by
    # default, dialed by the deploy block; bit-identical to pure interpretation.
    # The compiled-program lane is default-ON (wb-lzav/Phase C): a single-purpose compute CLI through
    # bounded prewarm runs near-native, bit-identical to interp — a clean win, so it doesn't wait on the
    # shell-oriented global `washy_transpile` flag. Overridable per-call (`transpile: false`).
    transpile? = Keyword.get(opts, :transpile, true)

    # A compiled CLI is one main() with an internal hot loop — call-count tiering never fires (main runs
    # once). So for this lane we PREWARM bounded modules up front: small single-purpose programs go native
    # from call 1 (compile cached cross-run); big multicall modules (coreutils) skip and stay lazy/interp.
    if transpile?, do: Nexus.Washy.Transpile.prewarm_bounded(mod, "_start")

    case run(mod, "_start", [], Keyword.put(opts, :transpile, transpile?)) do
      {:ok, _r, out, _meta} -> {:ok, out}
      {:exit, _code, out} -> {:ok, out}
      {:trap, reason} -> {:error, {:trap, reason}}
      {:timeout} -> {:error, :timeout}
      {:error, e} -> {:error, e}
    end
  end
end
