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

    cond do
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
        case CommandRegistry.run(name, stdin, argv) do
          {:ok, out} when is_binary(out) -> {:ok, cap(out, max_output)}
          {:error, reason} -> {:error, {:command_failed, reason}}
          other -> {:error, {:command_failed, other}}
        end
    end
  end

  defp cap(out, max) when byte_size(out) > max, do: binary_part(out, 0, max)
  defp cap(out, _max), do: out

  defp deny(name, why) do
    Logger.warning("wb-broker: DENY exec #{inspect(name)} — #{why}")
  end
end
