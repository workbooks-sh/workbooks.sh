defmodule Nexus.Wasmer.Session do
  @moduledoc """
  An OPTIONAL **long-lived per-agent bash session** on Wasmer (Phase 6) — one persistent `wasmer run bash`
  process over the agent's `/work`, instead of a fresh subprocess per command. State (cwd, env vars, shell
  functions, job state) PERSISTS across commands, so stateful workflows work: `cd build && make`, `export
  KEY=…`, `for …` across calls.

  Two bonuses fall out of keeping bash ALIVE: (1) the prebuilt-bash teardown crash ("indirect call type
  mismatch", exit 45) is on bash EXIT — a session never exits between commands, so it never hits it; (2)
  it amortizes the wasmer spawn + module-instantiation cost, which feeds the density moat ([[beam-wasm-kernel]],
  #wb-sjg3) — a lean long-running cell instead of fork-per-command.

  The session is a supervised BEAM process (a Cell, in kernel terms): wall-clock-bounded per command, an
  idle-timeout that reaps the bash process, and a hard stop. Commands are framed with a unique sentinel so
  we know exactly where one command's output ends and read back its exit code.

      {:ok, s} = Session.start_link(host_dir)
      {out, 0} = Session.run(s, "cd /work && echo hi > a.txt")
      {"hi\\n", 0} = Session.run(s, "cat a.txt")   # cwd persisted from the previous command
      Session.stop(s)
  """
  use GenServer

  @sentinel "__WB_SESSION_END__"
  @default_timeout_ms 30_000
  @default_idle_ms 300_000

  # ── public API ──────────────────────────────────────────────────────────────────────────────────

  @doc """
  Start a session over `host_dir` (mounted at `/work`). Opts: `:use` (PATH packages, default the agent
  env), `:net` (bool), `:idle_ms` (reap after inactivity, default 5m), `:name` (GenServer name).
  """
  def start_link(host_dir, opts \\ []) when is_binary(host_dir) do
    {gen_opts, opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, {host_dir, opts}, gen_opts)
  end

  @doc "Run `line` in the session; returns `{output, exit_code}`. Wall-clock bounded (`:timeout_ms`)."
  def run(server, line, opts \\ []) when is_binary(line) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    GenServer.call(server, {:run, line, timeout}, timeout + 1_000)
  end

  @doc "Stop the session, killing the bash process."
  def stop(server), do: GenServer.stop(server, :normal)

  # ── GenServer ───────────────────────────────────────────────────────────────────────────────────

  @impl true
  def init({host_dir, opts}) do
    use_pkgs = Keyword.get(opts, :use, Nexus.Wasmer.env())

    flags =
      ["run", Nexus.Wasmer.bash_pkg()]
      |> Kernel.++(Enum.flat_map(use_pkgs, fn p -> ["--use", p] end))
      |> Kernel.++(if Keyword.get(opts, :net, false), do: ["--net"], else: [])
      # `-i` (interactive) so wasmer's TTY bridge LINE-buffers stdout — without it, WASIX bash
      # block-buffers over the stdin/stdout pipe and the per-command sentinel never streams back until
      # exit. PS1='' (set at prime) suppresses the prompt the interactive shell would otherwise print.
      |> Kernel.++(["--volume", "#{host_dir}:/work", "--", "-i"])

    port =
      Port.open({:spawn_executable, Nexus.Wasmer.bin()}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        {:args, flags}
      ])

    # Quiet the interactive prompt + land in /work, then PRIME synchronously: send a sentinel and drain
    # the port up to it RIGHT HERE in init, so the setup banner never bleeds into the first command and
    # every later run/2 is a clean one-sentinel request/response (no prime-vs-run race).
    Port.command(port, "PS1='';PS2='';cd /work 2>/dev/null\n" <> sentinel_cmd())
    rest = drain_to_sentinel(port, "", 15_000)

    state = %{
      port: port,
      buffer: rest,
      waiting: nil,
      idle_ms: Keyword.get(opts, :idle_ms, @default_idle_ms),
      idle_timer: nil,
      primed: true
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:run, line, _timeout}, from, state) do
    Port.command(state.port, line <> "\n" <> sentinel_cmd())
    timer = Process.send_after(self(), :idle_timeout, state.idle_ms)
    {:noreply, %{state | waiting: {:run, from}, idle_timer: timer}}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    buffer = state.buffer <> data

    case split_on_sentinel(buffer) do
      :incomplete ->
        {:noreply, %{state | buffer: buffer}}

      {:done, output, code, rest} ->
        state = deliver(state, output, code)
        {:noreply, %{state | buffer: rest}}
    end
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    # bash died (crash or unexpected exit) — fail any in-flight caller, then stop.
    case state.waiting do
      {:run, from} -> GenServer.reply(from, {state.buffer, code})
      _ -> :ok
    end

    {:stop, :normal, state}
  end

  def handle_info(:idle_timeout, state), do: {:stop, :normal, state}
  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) do
    if is_port(port) and Port.info(port), do: Port.close(port)
    :ok
  end

  # ── internals ───────────────────────────────────────────────────────────────────────────────────

  # Echo the previous command's exit code wrapped in the sentinel, on its own line, so we can locate the
  # end of one command's output and read its `$?`.
  defp sentinel_cmd, do: "__rc=$?; printf '\\n#{@sentinel}%d\\n' \"$__rc\"\n"

  # Block (in init) until the prime sentinel arrives; return whatever followed it. Bounded so a wasmer
  # that never boots fails the start instead of hanging forever.
  defp drain_to_sentinel(port, acc, timeout) do
    case split_on_sentinel(acc) do
      {:done, _out, _code, rest} ->
        rest

      :incomplete ->
        receive do
          {^port, {:data, data}} -> drain_to_sentinel(port, acc <> data, timeout)
          {^port, {:exit_status, _}} -> acc
        after
          timeout -> acc
        end
    end
  end

  defp split_on_sentinel(buffer) do
    case Regex.run(~r/\n?#{@sentinel}(\d+)\n/, buffer, return: :index) do
      [{start, len}, {cstart, clen}] ->
        output = binary_part(buffer, 0, start)
        code = buffer |> binary_part(cstart, clen) |> String.to_integer()
        rest = binary_part(buffer, start + len, byte_size(buffer) - start - len)
        {:done, output, code, rest}

      _ ->
        :incomplete
    end
  end

  # Reply to the waiting caller with the captured output + exit code (the prime is drained synchronously
  # in init, so every sentinel seen here belongs to a run).
  defp deliver(%{waiting: {:run, from}} = state, output, code) do
    if t = state[:idle_timer], do: Process.cancel_timer(t)
    GenServer.reply(from, {Nexus.Wasmer.sanitize(output), code})
    %{state | waiting: nil}
  end

  defp deliver(state, _output, _code), do: state
end
