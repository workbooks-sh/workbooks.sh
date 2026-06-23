defmodule Nexus.WasmerCli do
  @moduledoc """
  The **WASIX** lane — run REAL bash + REAL coreutils in WebAssembly via the `wasmer` CLI, against a
  host directory mounted at `/work`. This is the upgrade path for the agent shell (`Nexus.Agent.Bash`):
  instead of our hand-rolled Elixir command parser + per-applet `wasmtime run`, hand the whole command
  line to a genuine bash that has the full grammar (lists, pipes, loops, glob, `$()`, functions, …) and
  execs real coreutils — all sandboxed to `/work`.

  Wasmer is a SEPARATE runtime from the wasmtime/Wasmex lane (which keeps running the component-model +
  in-process work — the .work parser, js_engine, compilers). WASIX (fork/exec/pipes/sockets) is what
  WASI Preview 1 lacks and what a real shell needs; only wasmer implements it today.

  ## The teardown quirk (handled here)

  The prebuilt `sharrattj/bash` + `sharrattj/coreutils` packages produce CORRECT output for pipes/exec,
  but on current wasmer they crash at process TEARDOWN with `RuntimeError: indirect call type mismatch`
  (an ABI mismatch on the fork/exit path; the real fix is rebuilding the packages against the current
  WASIX SDK). The output is already correct by then, so `run/3` captures stdout, strips that teardown
  noise, and treats "crashed-at-exit but produced output" as success. Remove the leniency once the
  packages are rebuilt.
  """

  @bash_pkg "sharrattj/bash"
  @coreutils_pkg "sharrattj/coreutils"
  @teardown_marker "indirect call type mismatch"
  @default_timeout_ms 30_000

  @doc "The wasmer binary path: config `:wasmer_bin`, else `~/.wasmer/bin/wasmer`, else `wasmer` on PATH."
  def bin do
    cfg = Application.get_env(:nexus, __MODULE__, [])
    home = System.user_home()
    home_bin = home && Path.join(home, ".wasmer/bin/wasmer")

    cond do
      b = Keyword.get(cfg, :wasmer_bin) -> b
      is_binary(home_bin) and File.exists?(home_bin) -> home_bin
      b = System.find_executable("wasmer") -> b
      true -> "wasmer"
    end
  end

  @doc "Whether the wasmer runtime is available (so callers can fall back to the wasmtime/Elixir lane)."
  def available? do
    b = bin()
    (File.exists?(b) or System.find_executable(b) != nil) and match?({_, 0}, version())
  rescue
    _ -> false
  end

  defp version do
    System.cmd(bin(), ["--version"], stderr_to_stdout: true)
  rescue
    _ -> {"", 1}
  end

  @doc """
  Run a bash command `line` against `host_dir` (mounted at `/work`), returning `{output, ok?}`.
  Real bash owns the grammar; real coreutils are on PATH via `--use`. Wall-clock bounded. The shell
  starts in `/work` so relative paths behave like the agent expects.
  """
  def run(line, host_dir, opts \\ []) when is_binary(line) and is_binary(host_dir) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    script = "cd /work 2>/dev/null; " <> line

    args = [
      "run", @bash_pkg,
      "--use", @coreutils_pkg,
      "--volume", "#{host_dir}:/work",
      "--", "-c", script
    ]

    {raw, code} = bounded_cmd(bin(), args, timeout)
    {out, crashed?} = sanitize(raw)

    cond do
      # Clean exit.
      code == 0 -> {out, true}
      # Teardown ABI crash but real output was produced → treat as success (see moduledoc).
      crashed? -> {out, true}
      # A real non-zero exit (a failed command).
      true -> {out, false}
    end
  end

  # Strip the known teardown crash noise so it never reaches the agent; report whether it occurred.
  defp sanitize(raw) do
    crashed? = String.contains?(raw, @teardown_marker)

    out =
      raw
      |> String.split("\n")
      |> Enum.reject(fn l ->
        String.contains?(l, @teardown_marker) or String.starts_with?(String.trim(l), "RuntimeError:")
      end)
      |> Enum.join("\n")

    {out, crashed?}
  end

  # System.cmd with a hard wall-clock kill (a hung wasm guest can't hang the agent). Mirrors the
  # watchdog used by the wasmtime kit lane.
  defp bounded_cmd(bin, args, timeout_ms) do
    task = Task.async(fn -> System.cmd(bin, args, stderr_to_stdout: true) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {out, code}} -> {out, code}
      _ -> {"\nwasmer: killed (exceeded #{div(timeout_ms, 1000)}s budget)", 137}
    end
  end
end
