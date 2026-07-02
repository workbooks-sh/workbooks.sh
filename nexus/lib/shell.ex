defmodule Nexus.Shell do
  @moduledoc """
  **washy** — our own featured shell, `priv/shell/sh.c` compiled to ONE wasm command module
  (clang.wasm → wasm32-wasip1) and run IN-PROCESS on the **tiny-lasers** WASM→BEAM substrate
  (`TinyLasers.Wasm`; the interp/asm lanes, BEAM-isolated + fuel/wall/memory bounded — no wasmtime
  subprocess). This is "bash in WASM": the agent's shell with NO wasmer, NO WASIX, NO fork. A real
  shell needs fork/exec only for pipes between processes — washy does pipes by BUFFERED CHAINING
  inside one module (`grep(cat(x))`), so it runs as a single dense command. Tools are builtins
  compiled in (+ real coreutils via `host_exec`); files are read/written over the agent's `/work`
  (mounted into the module). Featured, not real-bash — enough grammar for an agent's batch work
  (pipes `|`, `;`/`&&`/`||`, redirects `>`/`>>`, quoting, a coreutils-ish builtin set).

  Source: `priv/shell/sh.c`. Compiled once + cached (rebuilds when the source changes).

      {out, ok?} = Nexus.Shell.run("cat /work/a.txt | grep foo | wc -l", host_dir)
  """

  @doc "Whether the in-house shell can build (the C wasm lane is present)."
  def available? do
    File.dir?(Nexus.Compilers.Shared.default_root()) and File.exists?(src())
  end

  @doc """
  Run a shell command `line` over `host_dir` (mounted at `/work`). Returns `{output, ok?}`. The line is
  fed to the shell as stdin (the agent's bash line); the shell reads its inputs from files in `/work`.

  Executed on **Washy** — the shell wasm runs IN-PROCESS on the pure-Elixir interpreter, BEAM-isolated
  and bounded (fuel + wall-clock + memory), in a fresh Task so a runaway command can't harm the host.
  No wasmtime subprocess, no fork: this is the dense lane (thousands of cells/GB). `host_dir` is bridged
  to Washy's virtual FS (load in, flush writes back); the prod path uses the tenant-scoped SQLite VFS.
  """
  def run(line, host_dir, opts \\ []) when is_binary(line) and is_binary(host_dir) do
    case wasm() do
      nil -> {"shell: unavailable (wasm C lane not built)", false}
      w -> run_washy(w, line, host_dir, opts)
    end
  end

  @doc """
  Best-effort warm of the shared caches (shell wasm build + coreutils program registry) so the first
  concurrent burst of agent runs doesn't each race to decode the 9.6MB registry. Safe to call at boot.
  """
  def warm do
    case wasm() do
      nil ->
        :ok

      _path ->
        programs()
        :ok
    end
  rescue
    _ -> :ok
  end

  # Per-run bounds come from the deploy block (Nexus.Config.washy_limits) — neutral defaults if config
  # isn't loaded (tests/dev). Caller opts override.
  defp limits(opts) do
    base = try do
      Nexus.Config.washy_limits()
    rescue
      _ -> [fuel: 2_000_000_000, timeout_ms: 30_000, max_output: 16 * 1024 * 1024, max_depth: 10_000, max_pages: 4096]
    end

    Keyword.merge(base, opts)
  end

  # Runs on TinyLasers.Wasm (the vendor-back substrate; the former in-tree Nexus.Washy,
  # now deleted). The whole pdict contract is unified on `:tl_*` — the keys bash.ex/the app
  # set (`:tl_host_dispatch`, `:tl_env`, …) and the keys the substrate reads (backend, vfs,
  # stdin, argv, fds, programs, out, last_fuel) plus the exit-throw tag `:tl_exit`.
  defp run_washy(wasm_path, line, host_dir, opts) do
    {:ok, mod} = TinyLasers.Wasm.decode_cached(File.read!(wasm_path))
    opts = limits(opts)
    timeout = Keyword.get(opts, :timeout_ms, 30_000)
    # FS backend: default :map bridged to `host_dir` on disk (local/desktop); `{:store, tenant}` runs
    # diskless against the tenant-partitioned SQLite VFS (prod multi-tenant) — no host_dir load/flush.
    backend = Keyword.get(opts, :backend, :map)
    vfs0 = if backend == :map, do: load_dir(host_dir), else: %{}

    progs = programs()
    dispatch = Process.get(:tl_host_dispatch)   # carry an optional host-cap hook into the Task
    # Carry the run-scoped env + exec policy into the Task (opts win; else inherit the caller's). The app
    # sets these to inject a CLI connection's credentials (`env`) and enforce its scope (`exec_policy`).
    env = Keyword.get(opts, :env) || Process.get(:tl_env, [])
    exec_policy = Keyword.get(opts, :exec_policy) || Process.get(:tl_exec_policy)
    http = Keyword.get(opts, :http) || Process.get(:tl_http)   # host HTTP transport for guest CLIs
    sock = Keyword.get(opts, :sock) || Process.get(:tl_sock)   # host TCP transport (Layer 2)
    # Tiered wasm→BEAM transpilation for the shell module (native-compile hot functions). Cached per
    # module, so only the first shell run pays the build; bit-identical to interp (oracle-gated).
    transpile? = Keyword.get_lazy(opts, :transpile, fn -> try do Nexus.Config.washy_transpile?() rescue _ -> true end end)

    # backpressure: wait for a concurrency slot (bounded by the run timeout) before admitting the run
    admit(opts, timeout)

    # the meter lives OUTSIDE the Task so a timeout-killed run still records + the in-flight gauge
    # never leaks. The Task reports fuel-consumed back; the outer case classifies the outcome.
    meter = TinyLasers.Wasm.Metrics.start_run(TinyLasers.Wasm.mem_slots(mod) * 8)

    task =
      Task.async(fn ->
        Process.put(:tl_backend, backend)
        Process.put(:tl_vfs, vfs0)
        Process.put(:tl_stdin, line)
        Process.put(:tl_argv, ["sh"])
        Process.put(:tl_fds, %{})
        Process.put(:tl_nextfd, 4)
        Process.put(:tl_programs, progs)
        if dispatch, do: Process.put(:tl_host_dispatch, dispatch)
        if http, do: Process.put(:tl_http, http)
        if sock, do: Process.put(:tl_sock, sock)
        if env != [], do: Process.put(:tl_env, env)
        if exec_policy, do: Process.put(:tl_exec_policy, exec_policy)

        {code, out} =
          try do
            {_r, o} = TinyLasers.Wasm.call_io(mod, "_start", [], Keyword.put(opts, :transpile, transpile?))
            {0, o}
          catch
            :throw, {:tl_exit, c} ->
              {c, Process.get(:tl_out, []) |> Enum.reverse() |> IO.iodata_to_binary()}
          end

        fuel_used =
          case Process.get(:tl_last_fuel) do
            {budget, ref} -> max(0, budget - :atomics.get(ref, 1))
            _ -> 0
          end

        {code, out, Process.get(:tl_vfs, vfs0), fuel_used}
      end)

    max_out = Keyword.get(opts, :max_output, 16 * 1024 * 1024)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {code, out, vfs, fuel_used}} ->
        TinyLasers.Wasm.Metrics.finish_run(meter, :ok, fuel_used: fuel_used, out_bytes: byte_size(out))
        if backend == :map, do: flush_dir(host_dir, vfs, vfs0)   # store backend persists in SQLite, no disk flush
        {clip(out, max_out), code == 0}

      {:ok, other} ->
        TinyLasers.Wasm.Metrics.finish_run(meter, :error)
        {"shell: #{inspect(other)}", false}

      {:exit, reason} ->
        TinyLasers.Wasm.Metrics.finish_run(meter, :error)
        {"shell: crashed (#{inspect(reason)})", false}

      nil ->
        TinyLasers.Wasm.Metrics.finish_run(meter, :timeout)
        {"shell: killed (>#{timeout}ms)", false}
    end
  end

  defp clip(bin, max) when byte_size(bin) <= max, do: bin
  defp clip(bin, max), do: binary_part(bin, 0, max)

  # Soft concurrency backpressure: if in-flight runs are at the cap, wait (polling the gauge) for a slot
  # up to the run's own timeout, then proceed anyway (never hard-reject an agent command).
  defp admit(opts, timeout) do
    cap =
      Keyword.get(opts, :max_concurrent) ||
        (try do
           Nexus.Config.washy_max_concurrent()
         rescue
           _ -> 512
         end)

    if cap > 0, do: wait_for_slot(cap, System.monotonic_time(:millisecond) + timeout)
  end

  defp wait_for_slot(cap, deadline) do
    if TinyLasers.Wasm.Metrics.snapshot().in_flight >= cap and System.monotonic_time(:millisecond) < deadline do
      Process.sleep(5)
      wait_for_slot(cap, deadline)
    end
  end

  # The program registry host_exec resolves against: coreutils as the multicall `:default`, so any
  # non-builtin command the shell hits (seq, printf, cut, basename, …) runs the real tool. PLUS every
  # file-backed kit (`kits/*.wasm`) registered BY NAME, so a vendored CLI dropped in — e.g. `gws` — is
  # invocable as itself (`resolve_program("gws")`), not swallowed by the coreutils default. Memoized
  # (decode once, share) — the 9.6MB coreutils module isn't re-read/re-decoded per shell invocation.
  defp programs do
    case :persistent_term.get({__MODULE__, :programs}, nil) do
      nil ->
        default =
          case coreutils_path() do
            nil -> %{}
            path -> {:ok, m} = TinyLasers.Wasm.decode_cached(File.read!(path)); %{default: m}
          end

        named =
          Nexus.Agent.Kits.all()
          |> Enum.filter(fn {name, k} -> name != "coreutils" and is_binary(k[:wasm]) and File.exists?(k.wasm) end)
          |> Map.new(fn {name, k} -> {:ok, m} = TinyLasers.Wasm.decode_cached(File.read!(k.wasm)); {name, m} end)

        progs = Map.merge(named, default)
        :persistent_term.put({__MODULE__, :programs}, progs)
        progs

      progs ->
        progs
    end
  end

  defp coreutils_path do
    ["kits/coreutils.wasm", Path.join(:code.priv_dir(:nexus), "kits/coreutils.wasm")]
    |> Enum.find(&File.exists?/1)
  end

  # ── host_dir ↔ Washy virtual FS bridge (local/desktop; prod uses the tenant SQLite VFS) ──────────
  defp load_dir(host_dir) do
    if File.dir?(host_dir) do
      Path.wildcard(Path.join(host_dir, "**"))
      |> Enum.filter(&File.regular?/1)
      |> Map.new(fn p -> {Path.relative_to(p, host_dir), File.read!(p)} end)
    else
      %{}
    end
  end

  # write back files that are new or changed (the shell's redirects/creates); leaves untouched files alone
  defp flush_dir(host_dir, vfs, vfs0) do
    # write new/changed files
    Enum.each(vfs, fn {rel, bytes} ->
      if Map.get(vfs0, rel) != bytes do
        path = Path.join(host_dir, rel)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, bytes)
      end
    end)

    # propagate DELETIONS: a file present at load but gone from the final VFS (rm/mv) is removed on disk
    for {rel, _} <- vfs0, not Map.has_key?(vfs, rel), do: File.rm(Path.join(host_dir, rel))
  end

  @doc "The compiled shell wasm path (built + cached on first use; nil if the lane is unavailable)."
  def wasm do
    cache = Path.join(System.tmp_dir!(), "wb_washy.wasm")
    src = src()

    cond do
      fresh?(cache, src) -> cache
      not available?() -> nil
      true -> build(cache)
    end
  rescue
    _ -> nil
  end

  # Cache is valid when it exists and is newer than the source (rebuild on a source edit).
  defp fresh?(cache, src) do
    File.exists?(cache) and File.exists?(src) and File.stat!(cache).mtime >= File.stat!(src).mtime
  end

  defp build(cache) do
    case Nexus.Compilers.C.compile_to_wasm(src(), shape: :command) do
      {:ok, wasm} -> File.cp!(wasm, cache); cache
      _ -> nil
    end
  end

  defp src, do: Path.join(:code.priv_dir(:nexus), "shell/sh.c")
end
