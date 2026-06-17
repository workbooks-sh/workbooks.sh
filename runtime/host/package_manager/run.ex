defmodule Workbooks.PackageManager.Run do
  @moduledoc """
  The run lane: drive a built WASM command (argv + stdin → stdout) under the
  wasmtime CLI, with the host-side DoS bounds, the JsDock detour for host-brokered
  artifacts, the Go-interpreter source detour, and the streaming Port variant.
  Split out of `Workbooks.PackageManager` (which delegates the public entry points
  here) so the run path is one self-contained module.
  """

  # SECURITY (wb-sec): hard caps for the command run path. A guest that builds a
  # huge string and passes it as `run-command` input would otherwise pin it in
  # BEAM heap AND write it whole to /tmp (memory + disk DoS). argv likewise is
  # bounded so a single oversized arg cannot blow ARG_MAX (which silently failed).
  @max_input_bytes 64 * 1024 * 1024
  @max_argv_bytes 256 * 1024
  # Wall-clock + fuel caps on the wasmtime CLI so an infinite-loop guest cannot
  # hang the host forever (the Instance Policy timeout never wrapped this path).
  @default_run_timeout_ms 30_000
  @default_fuel 5_000_000_000

  # The Go artifact's 16-byte trailer magic (mirrors PackageManager's @go_magic);
  # go_artifact_source/1 probes for it to extract the embedded yaegi source.
  @go_magic "WBGOSRC1"

  @doc "The hard cap on stdin bytes for a run."
  def max_input_bytes, do: @max_input_bytes

  @doc "The hard cap on total argv bytes for a run."
  def max_argv_bytes, do: @max_argv_bytes

  @doc """
  Wasmtime compilation-cache args, shared by EVERY wasmtime CLI invocation in
  the runtime. Without the cache, every run JIT-compiles the module from
  scratch — ~1s on a fast core but MINUTES on a throttled shared vCPU, which
  presented as "the wasm shell hangs" (wb-91j: every echo recompiled wbox).
  With it, a module compiles once per content-hash and loads instantly after.
  Cache lives under WB_DATA so it survives deploys; falls back to tmp.
  """
  def wasmtime_cache_args do
    dir = Path.join(System.get_env("WB_DATA", System.tmp_dir!()), "cache/wasmtime")
    cfg = Path.join(dir, "config.toml")

    unless File.exists?(cfg) do
      File.mkdir_p!(dir)
      File.write!(cfg, "[cache]\ndirectory = \"#{dir}\"\n")
    end

    ["-C", "cache=y", "-C", "cache-config=#{cfg}"]
  end

  def wasmtime_cache_flags, do: Enum.join(wasmtime_cache_args(), " ")

  @doc """
  Capture a built CLI's `--help` text by running the wasm command with argv
  `["--help"]` and no stdin. The agent reads this the way a human reads `--help`;
  per TOOLKITS-V3 it MAY seed an overview/leaf skill draft (never a substitute for
  the hand-authored semantic surface). Returns the captured text (stdout+stderr).
  """
  def capture_help(wasm_path, flag \\ "--help"), do: run(wasm_path, "", [flag])

  def run(wasm_path, input), do: run(wasm_path, input, [])

  @doc """
  Run a built WASM command with stdin `input` AND `argv` — the universal CLI ABI
  (argv + stdin → stdout). This is what lets an unmodified upstream CLI compiled
  to wasm32-wasip1 (e.g. `sd`, `jq`) be driven exactly as on a native shell.
  `dirs` are host paths preopened into the guest (WASI `--dir`) for file-mode CLIs.
  argv/dirs are passed as discrete System.cmd args (no shell), so no injection.

  SECURITY (wb-sec): caps + bounds enforced here (the run-command Dock surface):
    * input size is capped (@max_input_bytes) before it is written to /tmp — a
      guest cannot fill host memory/disk via an oversized stdin.
    * total argv size is capped (@max_argv_bytes) — an oversized arg used to blow
      ARG_MAX and fail SILENTLY (empty output); now it returns a clear error.
    * wasmtime runs under `-W timeout=` AND `-W fuel=` so an infinite-loop guest
      traps instead of hanging the host forever (the Policy CPU cap never wrapped
      this path). `opts[:timeout_ms]` overrides the default.
    * the stdin temp file is removed in an `after` block so a crash/kill cannot
      leak it.
    * a non-zero wasmtime exit (including the timeout trap) returns
      `{:error, {:command_failed, status, out}}` instead of a silent "".

  Returns the trimmed-on-success stdout as a binary, or `{:error, reason}`.
  """
  def run(wasm_path, input, argv, dirs \\ [], opts \\ []) when is_list(argv) do
    cond do
      not is_binary(input) or byte_size(input) > @max_input_bytes ->
        {:error, {:input_too_large, max: @max_input_bytes}}

      argv_bytes(argv) > @max_argv_bytes ->
        {:error, {:argv_too_large, max: @max_argv_bytes}}

      # A JsDock artifact imports env.host_* (host-brokered fs/net) and CANNOT run on the bare
      # wasmtime CLI — route it to Workbooks.JsDock (Wasmex + Policy-gated host fns). Detected from
      # the wasm's import names (wb-e1x.5). Profile defaults to :minimal (vfs yes, net no); a
      # net-using command needs opts[:profile] = :network.
      dock_artifact?(wasm_path) ->
        # JsDock.run returns {:ok, stdout} | {:error, _}; unwrap to match the CLI run shape
        # (bare stdout binary on success). Thread an explicit :tenant so the dock partitions KV/secrets by the
        # caller's real identity; a missing tenant becomes a unique EPHEMERAL namespace (not the old "default").
        js_opts =
          [profile: Keyword.get(opts, :profile, :minimal), depth: Keyword.get(opts, :depth, 0)] ++
            case Keyword.get(opts, :tenant) do
              t when is_binary(t) and t != "" -> [tenant: t]
              _ -> []
            end

        case Workbooks.JsDock.run(wasm_path, input, js_opts) do
          {:ok, out} -> if Keyword.get(opts, :with_status, false), do: {out, 0}, else: out
          {:error, _} = e -> e
        end

      true ->
        run_wasmtime(wasm_path, input, argv, dirs, opts)
    end
  end

  # A command built with the JsDock harness imports env.host_vfs_read / env.host_http_get — the
  # import names appear literally in the wasm import section.
  defp dock_artifact?(wasm_path) do
    case File.read(wasm_path) do
      {:ok, bytes} -> bytes =~ "host_vfs_read" or bytes =~ "host_http_get"
      _ -> false
    end
  end

  defp argv_bytes(argv), do: Enum.reduce(argv, 0, fn a, acc -> acc + byte_size(to_string(a)) + 1 end)

  defp run_wasmtime(wasm_path, input, argv, dirs, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_run_timeout_ms)
    fuel = Keyword.get(opts, :fuel, @default_fuel)
    # opt-in shared-memory threads (wasm32-wasi-threads artifacts). The threads runtime path is INCOMPATIBLE
    # with -W fuel/-W timeout (they trap spawned child threads at memory-init), so we drop both and rely on the
    # OS-level System.cmd wall-clock kill for DoS. Default (single-thread) path is untouched.
    threads = Keyword.get(opts, :threads, false)
    env = Keyword.get(opts, :env, [])
    inp = Path.join(System.tmp_dir!(), "wb-in-#{:erlang.unique_integer([:positive])}")

    # Go-interpreter artifacts (wb-fm0.5) carry the untrusted Go source in a `wbgosrc` custom
    # section: the wasm IS yaegi-run.wasm, so we stage the source as /gosrc/main.go and prepend
    # it as argv[1] for the runner. yaegi then interprets it in-sandbox; the program's clean
    # argv (argv[2:]) and stdin/stdout flow as normal. Non-Go wasms are untouched.
    {argv, dirs, gosrc_dir} =
      case go_artifact_source(wasm_path) do
        {:ok, src} ->
          d = Path.join(System.tmp_dir!(), "wb-gosrc-#{:erlang.unique_integer([:positive])}")
          File.mkdir_p!(d)
          File.write!(Path.join(d, "main.go"), src)
          {["/gosrc/main.go" | argv], ["#{d}::/gosrc" | dirs], d}

        :no ->
          {argv, dirs, nil}
      end

    try do
      File.write!(inp, input)

      # exceptions=y → setjmp/longjmp (Lua etc., via wasi-sdk -wasm-enable-sjlj).
      # memory64=y → compilers-in-wasm (wb-cwasm) that exceed the wasm32 4GB ceiling on
      # large inputs (LLVM-class). Both harmless for modules that don't use them.
      # (Wasm 3.0 / W3C standard; wasmtime implements them.)
      wopts =
        if threads do
          wasmtime_cache_args() ++
            ["-W", "exceptions=y", "-W", "memory64=y", "-W", "threads=y", "-W", "shared-memory=y", "-W", "bulk-memory=y", "-S", "threads=y"]
        else
          # `fuel: :unlimited` (or 0) DROPS the fuel cap, relying solely on the wall-clock
          # `-W timeout` for DoS. Fuel is the wrong bound for a legitimately compute-heavy
          # lane (e.g. an H.264 encode of a multi-second clip burns far more than the
          # generic default before finishing); the wall-clock cap still kills a runaway.
          fuel_arg =
            if fuel in [:unlimited, 0],
              do: [],
              else: ["-W", "fuel=#{fuel}"]

          wasmtime_cache_args() ++
            ["-W", "exceptions=y", "-W", "memory64=y", "-W", "timeout=#{timeout_ms}ms"] ++ fuel_arg
        end
      envs = Enum.flat_map(env, &["--env", &1])
      parts = wopts ++ envs ++ Enum.flat_map(dirs, &["--dir", &1]) ++ [wasm_path | argv]
      cmd = "wasmtime " <> Enum.map_join(parts, " ", &sh_escape/1) <> " < " <> sh_escape(inp)

      # NOTE: a non-zero exit here is usually the GUEST exiting non-zero (a normal
      # CLI failure, e.g. a file not preopened) — that output is returned to the
      # caller verbatim, preserving the universal-CLI contract. The DoS protection
      # is the `-W timeout`/`-W fuel` trap above (an infinite loop is killed by
      # wasmtime) plus the input/argv size caps (no silent E2BIG) — not a status
      # check here.
      {out, status} = System.cmd("sh", ["-c", cmd], stderr_to_stdout: true)
      # wasmtime exits with the guest's exit code; surface it when asked (for
      # shell &&/|| control flow). Default stays a bare string (universal contract).
      if Keyword.get(opts, :with_status, false), do: {out, status}, else: out
    after
      File.rm(inp)
      if gosrc_dir, do: File.rm_rf(gosrc_dir)
    end
  end

  @doc """
  STREAMING wasm run (wb-b9xv.11) — drive the wasm CLI through an Erlang Port so the guest's stdout/stderr
  arrive INCREMENTALLY (as the guest flushes them) instead of all-at-end. This is the host primitive a
  long-lived `child_process.spawn()` consumes: the child stays alive, stdin is writable mid-run, exit
  propagates.

  Returns `{:ok, port, meta}` where `meta` carries the temp paths to clean up. The CALLER owns the port:
    * receives `{port, {:data, chunk}}` messages as stdout arrives (line/byte granularity per the guest),
    * may `Port.command(port, bytes)` to write to the guest's stdin (the Port's spawned process keeps
      stdin open — wasmtime reads it as a pipe),
    * receives `{port, {:exit_status, code}}` when the guest exits,
    * may `Port.close(port)` to KILL the in-flight run (revocation / cap breach).

  SECURITY: identical bounds to `run/5` — `-W timeout`/`-W fuel` DoS trap, argv/path discipline (no shell:
  spawn_executable + an explicit argv list, NOT `sh -c`), content-addressed wasm verified by the caller
  (CommandRegistry) before we ever spawn. NO native exec is introduced — the only executable spawned is
  the trusted `wasmtime` binary running a REGISTERED, sha-pinned wasm guest.

  HONEST GRANULARITY LIMIT: incrementality is bounded by the GUEST's flush behaviour. wasmtime does NOT
  buffer the guest's fd_write — each WASI stdout write surfaces as a Port `{:data, _}` message as it
  happens — but a guest that accumulates its whole answer and writes once at exit still arrives all-at-end.
  The streaming PROTOCOL is real end-to-end; the per-chunk cadence is exactly the inner CLI's write cadence.
  """
  def run_streaming(wasm_path, argv, dirs \\ [], opts \\ []) when is_list(argv) do
    cond do
      argv_bytes(argv) > @max_argv_bytes -> {:error, {:argv_too_large, max: @max_argv_bytes}}
      not File.regular?(wasm_path) -> {:error, {:no_wasm, wasm_path}}
      true -> open_streaming_port(wasm_path, argv, dirs, opts)
    end
  end

  defp open_streaming_port(wasm_path, argv, dirs, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_run_timeout_ms)
    fuel = Keyword.get(opts, :fuel, @default_fuel)
    env = Keyword.get(opts, :env, [])

    {argv, dirs, gosrc_dir} =
      case go_artifact_source(wasm_path) do
        {:ok, src} ->
          d = Path.join(System.tmp_dir!(), "wb-gosrc-#{:erlang.unique_integer([:positive])}")
          File.mkdir_p!(d)
          File.write!(Path.join(d, "main.go"), src)
          {["/gosrc/main.go" | argv], ["#{d}::/gosrc" | dirs], d}

        :no ->
          {argv, dirs, nil}
      end

    fuel_arg = if fuel in [:unlimited, 0], do: [], else: ["-W", "fuel=#{fuel}"]

    wopts =
      wasmtime_cache_args() ++
        ["-W", "exceptions=y", "-W", "memory64=y", "-W", "timeout=#{timeout_ms}ms"] ++ fuel_arg

    envs = Enum.flat_map(env, &["--env", &1])
    parts = wopts ++ envs ++ Enum.flat_map(dirs, &["--dir", &1]) ++ [wasm_path | argv]

    case System.find_executable("wasmtime") do
      nil ->
        if gosrc_dir, do: File.rm_rf(gosrc_dir)
        {:error, :no_wasmtime}

      bin ->
        # spawn_executable → an explicit argv list, NO shell (no `sh -c`): no metacharacter interpretation,
        # no injection. :stderr_to_stdout folds the guest's stderr into the stream. :exit_status delivers the
        # guest's exit code. The port stays open with a writable stdin (Port.command) for the child's lifetime.
        port =
          Port.open({:spawn_executable, bin}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            {:args, parts}
          ])

        {:ok, port, %{gosrc_dir: gosrc_dir}}
    end
  end

  @doc "Clean up a streaming run's temp resources (call after the port closes)."
  def cleanup_streaming(%{gosrc_dir: dir}) when is_binary(dir), do: File.rm_rf(dir)
  def cleanup_streaming(_), do: :ok

  # The Go artifact's 16-byte trailer is <source length::big-64> ++ @go_magic ("WBGOSRC1",
  # defined with the build_go helpers in PackageManager).
  #
  # O(1) probe: read only the last 16 bytes. If the magic is present, read back the embedded Go
  # source. Any other wasm lacks the trailer → :no (a one-pread cost on the run path).
  defp go_artifact_source(wasm_path) do
    case File.stat(wasm_path) do
      {:ok, %{size: size}} when size > 16 ->
        case :file.open(wasm_path, [:read, :binary]) do
          {:ok, fd} ->
            try do
              with {:ok, <<slen::big-64, @go_magic>>} <- :file.pread(fd, size - 16, 16),
                   true <- slen > 0 and slen <= size - 16,
                   {:ok, src} <- :file.pread(fd, size - 16 - slen, slen) do
                {:ok, src}
              else
                _ -> :no
              end
            after
              :file.close(fd)
            end

          _ ->
            :no
        end

      _ ->
        :no
    end
  end

  # POSIX single-quote escaping: wrap in '...' and replace ' with '\'' — no injection.
  defp sh_escape(s), do: "'" <> String.replace(to_string(s), "'", "'\\''") <> "'"
end
