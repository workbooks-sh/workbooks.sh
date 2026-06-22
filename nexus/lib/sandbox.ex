defmodule Nexus.Sandbox do
  @moduledoc """
  Run a wasm component on **wasmex** — and that's the whole sandbox.

  We do NOT reinvent isolation, memory/CPU limits, a virtual filesystem, or a capability VM:
  wasmtime (via wasmex) already does all of that *inherently*. So this module is intentionally
  tiny — instantiate a component against its generated WIT world, hand it the host imports the
  `Nexus.Dock` grants, call it. wasmex marshals Elixir ↔ WIT across the boundary.

  The "no native code" system: every unit (rust/zig/c/js/python) is compiled to wasm by OUR
  compilers (the moat — `Nexus.Compile` brings them in) and runs *here*. Nothing executes
  natively; wasmex runs the wasm, the Dock mediates every host call. That's the entire model.

  (wasmex lands as a dep when we first run real wasm — the remote calls below compile as
  warnings until then, keeping `nexus` green while the shape is real.)
  """

  @doc """
  Instantiate a wasm component, wiring ONLY the granted capabilities as host imports, each bound to
  `tenant`. `caps` is the unit's grant words (from `Nexus.Capabilities.grants/1`); `tenant` is the
  caller's request tenant, captured here so a guest can never address another tenant's data nor reach
  a capability it didn't grant. Defaults are conservative: no extra caps, the default tenant.
  """
  def start(component_path, caps \\ [], tenant \\ Nexus.Store.default_tenant()) do
    Wasmex.Components.start_link(%{
      path: component_path,
      imports: imports_for(caps, tenant),
      store_limits: store_limits()
    })
  end

  @doc """
  The per-guest resource ceiling wasmtime enforces on every sandboxed component — a guest that
  exceeds it traps (its `memory.grow`/`table.grow` fails / instantiation is refused) instead of
  growing until the BEAM OS process OOM-kills every co-resident tenant. Values come from the deploy
  block via `Nexus.Config` (neutral safe defaults); a single guest is one instance with one memory
  and one table, so those are pinned to 1.
  """
  def store_limits do
    %Wasmex.StoreLimits{
      memory_size: Nexus.Config.sandbox_memory_mb() * 1024 * 1024,
      table_elements: Nexus.Config.sandbox_table_elements(),
      instances: 1,
      tables: 1,
      memories: 1
    }
  end

  @doc "Call an exported function on a running component — wasmex marshals the typed values."
  def call(pid, fun, args, timeout \\ 5_000) do
    Wasmex.Components.call_function(pid, fun, args, timeout)
  end

  @cmd_timeout_ms 30_000

  @doc """
  Run a WASI **command module** (`main()`, stdin→stdout — the js/ts/python lanes, and toolkits) and
  capture stdout. `spec` is either a `.wasm` path (a self-contained command, e.g. an embedded-JS
  module), or `{:interp, interp_path, source}` for an interpreter lane (python): the source is mounted
  and run by the interpreter. `stdin` is the program's input. Returns `{:ok, stdout} | {:error, _}`.

  Mirrors the agent's kit runner (`Nexus.Agent.Bash`): the host only does the `< stdin` redirect + a
  SIGKILL watchdog; the executed program is the sandboxed wasm.
  """
  def run_command(spec, stdin \\ "")

  def run_command(wasm, stdin) when is_binary(wasm), do: exec_command(wasm, [], [], stdin)

  def run_command({:interp, interp, source}, stdin) do
    dir = Path.join(System.tmp_dir!(), "nxcmd_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "main"), source)

    try do
      exec_command(interp, ["--dir", "#{dir}::/w"], ["/w/main"], stdin)
    after
      File.rm_rf(dir)
    end
  end

  # wasmtime run [aot flags] [extra mounts] <wasm> [argv] < stdinfile, with a kill-after-budget watchdog.
  defp exec_command(wasm, extra_flags, argv, stdin) do
    {flags, exec} = Nexus.Wasm.Aot.resolve(wasm)
    stdin_file = Path.join(System.tmp_dir!(), "nxcmd_in_#{System.unique_integer([:positive])}")
    File.write!(stdin_file, stdin)

    inner =
      (["wasmtime", "run"] ++ flags ++ extra_flags ++ [exec | argv]) |> Enum.map_join(" ", &shq/1)

    secs = max(1, div(@cmd_timeout_ms, 1000))

    guarded =
      "#{inner} < #{shq(stdin_file)} & cmd=$!; " <>
        "{ sleep #{secs}; kill -9 $cmd 2>/dev/null; pkill -9 -P $cmd 2>/dev/null; } >/dev/null 2>&1 & w=$!; " <>
        "wait $cmd; rc=$?; kill $w 2>/dev/null; wait $w 2>/dev/null; exit $rc"

    {out, code} = System.cmd("sh", ["-c", guarded], stderr_to_stdout: true)
    File.rm(stdin_file)

    cond do
      code == 0 -> {:ok, out}
      code == 137 -> {:error, {:command_timeout, secs}}
      true -> {:error, {:command_failed, code, out}}
    end
  end

  defp shq(s), do: "'" <> String.replace(to_string(s), "'", "'\\''") <> "'"

  # The Dock supplies the host implementations (the one place this layer holds real code —
  # everything else is wasmex). The import map is tenant-bound and filtered to the unit's grants:
  # an ungranted import is omitted (instantiation fails if the guest declares it), and every
  # stateful cap is partitioned by `tenant` so no guest can reach another tenant's data.
  defp imports_for(caps, tenant), do: Nexus.Dock.impls(tenant, caps)
end
