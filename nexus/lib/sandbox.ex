defmodule Nexus.Sandbox do
  @moduledoc """
  Run a wasm component on **wasmex** (wasmtime + the component model). Every unit (rust/zig/c/js/python)
  is compiled to wasm by OUR compilers and runs *here* — nothing executes natively; wasmex runs the
  wasm, the Dock mediates every host call.

  ## Isolation strength — read this before hosting untrusted code

  wasmtime's sandbox is **software fault isolation** (SFI): bounds-checked linear memory + control-flow
  integrity + capability-only I/O, enforced by the *compiler* (Cranelift). It is NOT a hardware/MMU
  boundary — a sandbox escape requires a codegen bug, and that class of CVE recurs and is fixed in
  wasmtime point releases (keep the vendored wasmex pinned current). So the **real trust boundary for
  mutually-distrusting tenants is the machine** (the Fly Firecracker microVM / one nexus per
  trust-domain); the in-process controls below are **defense-in-depth**, not a substitute.

  wasmtime does NOT do any of this "inherently" — the runtime ships safe DEFAULTS only because this
  module wires them on every instantiation (the wb-atsl hardening):

    * **Capability grant** — `imports_for/2` wires ONLY the caps a unit granted; an ungranted import is
      omitted, so the guest can't reach a capability it didn't declare (wb-ynlx).
    * **Tenant partition** — every stateful host cap is bound to the caller's `tenant` at instantiation,
      never guest-supplied, so no guest can address another tenant's data (wb-ynlx).
    * **Resource limits** — a populated `StoreLimits` (per-guest memory/table/instance caps) so a
      `memory.grow` loop traps instead of OOM-killing the shared BEAM; a per-call epoch deadline so a
      spinning guest traps and frees its thread (wb-9jqy). Values are neutral safe defaults from
      `Nexus.Config`; a single-trust-domain deployer can raise them.
    * **Concurrency** — the component lane runs under `Nexus.Wasm.Gate` (per-tenant fair) so one tenant
      can't fan out past the memory wall or starve others (wb-whvy).
    * **Egress** — host `fetch` is SSRF-guarded through the one `Nexus.Net.Ssrf` guard (wb-y4md).

  The command-module lane (`run_command/2`, js/python/toolkits) adds the same posture at the OS-process
  layer: wasmtime memory caps, a scrubbed (secret-free) subprocess env, read-only sysroot mounts.
  """

  @doc """
  Instantiate a wasm component, wiring ONLY the granted capabilities as host imports, each bound to
  `tenant`. `caps` is the unit's grant words (from `Nexus.Capabilities.grants/1`); `tenant` is the
  caller's request tenant, captured here so a guest can never address another tenant's data nor reach
  a capability it didn't grant. Defaults are conservative: no extra caps, the default tenant.
  """
  def start(component_path, caps \\ [], tenant \\ Nexus.Store.default_tenant()) do
    with {:ok, store} <- Wasmex.Components.Store.new(store_limits(), epoch_engine()) do
      Wasmex.Components.start_link(%{
        path: component_path,
        imports: imports_for(caps, tenant),
        store: store
      })
    end
  end

  # A single process-wide epoch-interruption engine (its 1s ticker advances the epoch). Built once
  # and memoized — every sandbox store shares it so a per-call `set_epoch_deadline` can trap a
  # runaway guest. Without an epoch engine the deadline is a no-op, so this is what makes the CPU
  # bound real.
  def epoch_engine do
    case :persistent_term.get({__MODULE__, :epoch_engine}, nil) do
      nil ->
        engine =
          case Wasmex.Engine.new(%Wasmex.EngineConfig{epoch_interruption: true}) do
            {:ok, e} -> e
            e -> e
          end

        :persistent_term.put({__MODULE__, :epoch_engine}, engine)
        engine

      engine ->
        engine
    end
  end

  @doc """
  The per-guest resource ceiling wasmtime enforces on every sandboxed component — a guest that
  exceeds it traps (its `memory.grow`/`table.grow` fails / instantiation is refused) instead of
  growing until the BEAM OS process OOM-kills every co-resident tenant. Values come from the deploy
  block via `Nexus.Config` (neutral safe defaults); a single guest is one instance with one memory
  and one table, so those are pinned to 1.
  """
  def store_limits do
    max = Nexus.Config.sandbox_max_instances()

    %Wasmex.StoreLimits{
      memory_size: Nexus.Config.sandbox_memory_mb() * 1024 * 1024,
      table_elements: Nexus.Config.sandbox_table_elements(),
      instances: max,
      tables: max,
      memories: max
    }
  end

  @doc """
  Call an exported function on a running component — wasmex marshals the typed values. The call
  carries a wall-clock epoch deadline (`Nexus.Config.sandbox_epoch_secs`): a guest that spins past it
  TRAPS and frees its worker thread, instead of the GenServer timeout returning while the wasm keeps
  running detached. `timeout` stays slightly above the deadline so the trap is what fires first.
  """
  def call(pid, fun, args, timeout \\ nil) do
    secs = Nexus.Config.sandbox_epoch_secs()
    timeout = timeout || (secs + 2) * 1000
    Wasmex.Components.call_function(pid, fun, args, timeout, secs)
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

  # wasmtime run [hardening] [aot flags] [extra mounts] <wasm> [argv] < stdinfile.
  #
  # Hardening (wb-od4a): a guest command module is UNTRUSTED, so it runs with wasmtime's own resource
  # caps — `-W timeout` (self-trapping wall-clock bound, so a spin can't run forever), a per-guest
  # `-W max-memory-size` (so a memory.grow loop traps instead of exhausting host RAM), and
  # `-W trap-on-grow-failure=y` (clean trap, not a silent -1). The subprocess env is SCRUBBED to a
  # tiny allowlist so neither the wrapper shell nor wasmtime carries WB_*/OPENROUTER_API_KEY secrets.
  defp exec_command(wasm, extra_flags, argv, stdin) do
    {flags, exec} = Nexus.Wasm.Aot.resolve(wasm)
    stdin_file = Path.join(System.tmp_dir!(), "nxcmd_in_#{System.unique_integer([:positive])}")
    # 0600 before the content lands: the guest's stdin is plaintext in a shared tmp dir — keep it
    # readable only by the nexus user.
    File.write!(stdin_file, "")
    File.chmod!(stdin_file, 0o600)
    File.write!(stdin_file, stdin)

    secs = max(1, div(@cmd_timeout_ms, 1000))
    mem = Nexus.Config.sandbox_proc_memory_mb() * 1024 * 1024

    # Memory hardening only — `-W max-memory-size` + `trap-on-grow-failure` need no epoch interruption,
    # so they stay compatible with the AOT `.cwasm` cache (precompiled without epoch). The wall-clock
    # CPU bound is the SIGKILL watchdog below (portable, epoch-free). A memory.grow loop now traps
    # instead of exhausting host RAM.
    hardening = ["-W", "max-memory-size=#{mem}", "-W", "trap-on-grow-failure=y"]

    inner =
      (["wasmtime", "run"] ++ hardening ++ flags ++ extra_flags ++ [exec | argv])
      |> Enum.map_join(" ", &shq/1)

    guarded =
      "#{inner} < #{shq(stdin_file)} & cmd=$!; " <>
        "{ sleep #{secs}; kill -9 $cmd 2>/dev/null; pkill -9 -P $cmd 2>/dev/null; } >/dev/null 2>&1 & w=$!; " <>
        "wait $cmd; rc=$?; kill $w 2>/dev/null; wait $w 2>/dev/null; exit $rc"

    # env is SCRUBBED (subprocess_env/0) so neither this wrapper shell nor wasmtime carries
    # WB_*/OPENROUTER_API_KEY secrets; every interpolated token is host-controlled + shq-escaped.
    {out, code} = System.cmd("sh", ["-c", guarded], env: subprocess_env(), stderr_to_stdout: true)
    File.rm(stdin_file)

    cond do
      code == 0 -> {:ok, out}
      code == 137 -> {:error, {:command_timeout, secs}}
      true -> {:error, {:command_failed, code, out}}
    end
  end

  defp shq(s), do: "'" <> String.replace(to_string(s), "'", "'\\''") <> "'"

  @doc """
  The SCRUBBED environment for an untrusted wasmtime subprocess (command lane + compiler lane). Every
  inherited var is unset (`{k, false}`) except a tiny operational allowlist — so a guest's host
  process can't read injected secrets (`OPENROUTER_API_KEY`, `WB_*`, tokens) via `getenv`, and neither
  can a wrapper shell. Guest-visible env is passed separately as explicit `--env NAME=VAL` flags.
  """
  @env_allow ~w(PATH HOME TMPDIR LANG LC_ALL LC_CTYPE USER SHELL TERM)
  def subprocess_env do
    for {k, _v} <- System.get_env(), k not in @env_allow, do: {k, nil}
  end

  # The Dock supplies the host implementations (the one place this layer holds real code —
  # everything else is wasmex). The import map is tenant-bound and filtered to the unit's grants:
  # an ungranted import is omitted (instantiation fails if the guest declares it), and every
  # stateful cap is partitioned by `tenant` so no guest can reach another tenant's data.
  defp imports_for(caps, tenant), do: Nexus.Dock.impls(tenant, caps)
end
