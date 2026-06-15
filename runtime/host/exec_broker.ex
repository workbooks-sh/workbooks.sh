defmodule Workbooks.ExecBroker do
  @moduledoc """
  wb-broker EXEC dispatch (Stone 2) — broker a GUEST's `exec(cmd)` to the in-sandbox CommandRegistry (the
  32+ wasm commands). The host performs the privileged op (running another sandboxed wasm command in its
  OWN isolated instance); the guest stays sandboxed. There is NO real OS exec — only REGISTERED wasm
  commands run.

  Security cadence (mirrors the net broker):
    * DEFAULT-DENY — a guest may exec only if its profile grants it (the `commands` cap; opts `:allow`).
    * COMMAND SCOPE — an optional per-instance allow-list (`:commands`) further restricts which commands.
    * NO INJECTION / NO ARG-SMUGGLING — args are a STRUCTURAL argv list handed straight to the command,
      never a shell string; `"; rm -rf /"` is just a literal argument, never interpreted.
    * BOUNDED NESTING — a depth limit stops exec-recursion bombs (a guest exec'ing guests that exec…).
    * SIZE-CAPPED OUTPUT + audit log on every denial.
  """
  require Logger
  alias Workbooks.CommandRegistry

  @default_max_output 8 * 1024 * 1024
  @max_depth 8
  # per-principal cap on TOTAL concurrent brokered execs (the unified fork-bomb WIDTH defense; @max_depth is
  # the depth defense). Generous enough for legit fan-out (ParallelBroker is 16-wide), tight enough that a
  # recursive process explosion can't OOM the host.
  @max_concurrent_exec 64
  @exec_slots :wb_exec_slots

  @doc """
  Run a sandboxed wasm command on behalf of a guest. Returns `{:ok, output}` | `{:error, reason}`.

  opts:
    * `:allow` (bool, DEFAULT false) — the guest's profile grants exec (derive from the `commands` cap).
    * `:commands` (`:all` | [name]) — which commands are reachable (default `:all` of the registry).
    * `:max_output` (bytes) — cap the returned output.
    * `:depth` (int) — current nesting depth; rejected past the bound.
  """
  def exec(name, argv, stdin, opts \\ [])
      when is_binary(name) and is_list(argv) and is_binary(stdin) do
    allow = Keyword.get(opts, :allow, false)
    commands = Keyword.get(opts, :commands, :all)
    max_output = Keyword.get(opts, :max_output, @default_max_output)
    depth = Keyword.get(opts, :depth, 0)
    principal = Keyword.get(opts, :principal)
    rate = Keyword.get(opts, :rate, Workbooks.RateLimiter.default_quota())

    cond do
      principal && Workbooks.Revocation.revoked?(principal) ->
        deny(name, "principal revoked")
        {:error, :revoked}

      principal && rate && rate_denied?(principal, rate) ->
        deny(name, "rate limited")
        {:error, :rate_limited}

      not allow ->
        deny(name, "not granted (no commands cap)")
        {:error, :denied}

      depth > @max_depth ->
        deny(name, "nesting depth exceeded")
        {:error, :max_depth}

      commands != :all and name not in commands ->
        deny(name, "not in the granted command list")
        {:error, :command_not_granted}

      name not in CommandRegistry.list() ->
        deny(name, "unknown/unregistered command")
        {:error, :unknown_command}

      true ->
        # UNIFIED FORK-BOMB DEFENSE (width): a per-PRINCIPAL cap on TOTAL concurrent brokered execs, acquired
        # HERE — the single choke point ALL exec callers pass through (host_exec, ParallelBroker.map's tasks,
        # ProcessBroker.spawn). The @max_depth bound limits recursion LEVELS but not total process count: a
        # recursive host_parallel_map fans out ~16^depth, and the (generous) rate cap alone would let it spawn
        # enough concurrent wasm instances to OOM the host. This concurrent cap bounds the LIVE total instead.
        max_conc = Keyword.get(opts, :max_concurrent, @max_concurrent_exec)

        if acquire_slot(principal, max_conc) do
          try do
            case CommandRegistry.run(name, stdin, argv, [], depth: depth) do
              {:ok, out} when is_binary(out) -> {:ok, cap(out, max_output)}
              {:error, reason} -> {:error, {:command_failed, reason}}
              other -> {:error, {:command_failed, other}}
            end
          after
            release_slot(principal)
          end
        else
          deny(name, "concurrent-exec cap exceeded")
          {:error, :too_many_processes}
        end
    end
  end

  @doc """
  STREAMING spawn (wb-b9xv.11) — start a LONG-LIVED `Workbooks.HarnessProc` for a registered wasm CLI,
  returning `{:ok, proc_pid}` | `{:error, reason}`. The child streams stdout/stderr incrementally, takes
  stdin writes, and propagates its exit code; it is killed if the principal is revoked.

  This runs the EXACT SAME default-deny / registered-only / command-scope / depth / concurrency / revocation
  gate as `exec/4` — the only difference is the work is a long-lived streaming child rather than a buffered
  one-shot. The per-principal concurrency slot is acquired HERE and held for the child's whole lifetime
  (released by HarnessProc on exit), so a streaming child counts against the fork-bomb width cap identically.
  NO native exec: the child is a sha-pinned registered wasm guest run by wasmtime (same substrate as `exec`).
  """
  def spawn_stream(name, argv, opts \\ [])
      when is_binary(name) and is_list(argv) do
    allow = Keyword.get(opts, :allow, false)
    commands = Keyword.get(opts, :commands, :all)
    depth = Keyword.get(opts, :depth, 0)
    principal = Keyword.get(opts, :principal)
    rate = Keyword.get(opts, :rate, Workbooks.RateLimiter.default_quota())

    cond do
      principal && Workbooks.Revocation.revoked?(principal) ->
        deny(name, "principal revoked")
        {:error, :revoked}

      principal && rate && rate_denied?(principal, rate) ->
        deny(name, "rate limited")
        {:error, :rate_limited}

      not allow ->
        deny(name, "not granted (no commands cap)")
        {:error, :denied}

      depth > @max_depth ->
        deny(name, "nesting depth exceeded")
        {:error, :max_depth}

      commands != :all and name not in commands ->
        deny(name, "not in the granted command list")
        {:error, :command_not_granted}

      name not in CommandRegistry.list() ->
        deny(name, "unknown/unregistered command")
        {:error, :unknown_command}

      true ->
        case CommandRegistry.resolve_wasm(name) do
          {:ok, wasm, run_argv, dirs, run_opts} ->
            max_conc = Keyword.get(opts, :max_concurrent, @max_concurrent_exec)

            if acquire_slot(principal, max_conc) do
              proc_opts = [
                wasm: wasm,
                argv: run_argv ++ Enum.map(argv, &to_string/1),
                dirs: dirs,
                run_opts: Keyword.put(run_opts, :depth, depth + 1),
                principal: principal,
                on_release: fn -> release_slot(principal) end
              ]

              case Workbooks.HarnessProc.start_link(proc_opts) do
                {:ok, proc} ->
                  {:ok, proc}

                other ->
                  release_slot(principal)
                  {:error, {:spawn_failed, other}}
              end
            else
              deny(name, "concurrent-exec cap exceeded")
              {:error, :too_many_processes}
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Parse the wire request a guest writes into wasm memory for `host_exec`. Length-prefixed, little-endian
  (wasm32 is LE), so binary args/stdin are safe (no delimiter ambiguity):

      [name_len:u32][name][argc:u32][ (arg_len:u32)(arg) ]*[stdin_len:u32][stdin]

  Returns `{:ok, name, argv, stdin}` | `:error` (malformed). Trailing bytes are tolerated.
  """
  def parse_request(bin) when is_binary(bin) do
    with <<nlen::little-32, name::binary-size(nlen), argc::little-32, rest1::binary>> <- bin,
         {:ok, argv, rest2} <- parse_args(rest1, argc, []),
         <<slen::little-32, stdin::binary-size(slen), _trailing::binary>> <- rest2 do
      {:ok, name, argv, stdin}
    else
      _ -> :error
    end
  end

  def parse_request(_), do: :error

  defp parse_args(rest, 0, acc), do: {:ok, Enum.reverse(acc), rest}

  defp parse_args(<<alen::little-32, arg::binary-size(alen), rest::binary>>, n, acc) when n > 0 do
    parse_args(rest, n - 1, [arg | acc])
  end

  defp parse_args(_, _, _), do: :error

  defp cap(out, max) when byte_size(out) > max, do: binary_part(out, 0, max)
  defp cap(out, _max), do: out

  defp rate_denied?(principal, {max, window}),
    do: Workbooks.RateLimiter.check(principal, max, window) == {:error, :rate_limited}

  # concurrent-exec slot: bump the principal's live count; if it exceeds the cap, roll back and refuse. nil
  # principal (host-internal calls) is uncapped. Atomic via :ets.update_counter on the long-lived table.
  defp acquire_slot(nil, _max), do: true

  defp acquire_slot(principal, max) do
    n = :ets.update_counter(slots(), principal, {2, 1}, {principal, 0})

    if n > max do
      :ets.update_counter(slots(), principal, {2, -1}, {principal, 0})
      false
    else
      true
    end
  end

  defp release_slot(nil), do: :ok
  defp release_slot(principal), do: :ets.update_counter(slots(), principal, {2, -1}, {principal, 0})

  defp slots, do: Workbooks.BrokerTables.ensure(@exec_slots, [:named_table, :public, :set])

  defp deny(name, why) do
    Workbooks.BrokerAudit.record(:exec, :deny)
    Logger.warning("wb-broker: DENY exec #{inspect(name)} — #{why}")
  end
end
