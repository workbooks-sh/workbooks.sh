defmodule Nexus.Membrane do
  @moduledoc """
  The **Membrane** (wb-g5w3) — the ONE bus through which HOST capabilities resolve, regardless of which
  wasm lane or transport asked. It is the first brick of the BEAM wasm kernel ([[beam-wasm-kernel]]): the
  thing that makes wasmex (components) and wasmer (the shell) feel like one system instead of two.

  A host capability (`work`/`agent`/`request`/`web`/`image|video|speak`) has, today, ONE transport: the
  agent's first-word path in `Nexus.Agent.Bash.run/3`, which intercepts the command before bash and
  dispatches it in Elixir. That works only when the cap is the FIRST word — it can't be piped or chained
  (`cat x | work parse`, `work check && ls`), because a sandboxed wasm guest can't call host functions.

  The Membrane generalizes that interception into a transport-agnostic seam. Both of these call the SAME
  dispatch (`Nexus.Agent.Bash.host_dispatch/5`), so a host cap behaves identically either way:

    * **first-word transport** — `Bash.run/3` (live today).
    * **socket transport** — a WASIX socket the in-sandbox shell can `exec` into (the SECOND brick): a
      tiny in-sandbox client connects, sends the command + argv + stdin, and reads the output back, so
      host caps become real commands bash can place anywhere in a pipe/chain. `handle_request/3` is the
      transport-agnostic CORE of that path — it decodes one wire frame and produces the response bytes,
      unit-testable without a real socket or a running wasmer.

  ## Wire frame (one-shot request/response per connection)

      <cmd>\\t<arg1>\\t<arg2>…\\n<raw stdin bytes…>

  The first line (up to the first `\\n`) is the TAB-joined command + argv; everything after it is stdin
  (may be empty, may be binary). The response is the host cap's combined output bytes. One request, one
  response, then the connection closes — matching a single `exec` of a command in a pipe.
  """

  alias Nexus.Agent.Bash

  @doc "Whether `cmd` resolves on the Membrane (a host cap) vs. is a real program for the wasm shell."
  defdelegate host_command?(cmd), to: Bash

  @doc """
  Dispatch a host capability through the Membrane. `vfs`/`perms` are the calling agent run's context
  (the socket transport binds them per-run). Returns `{:host, output}` or `:not_host`.
  """
  defdelegate dispatch(vfs, cmd, args, stdin, perms), to: Bash, as: :host_dispatch

  @doc """
  The transport-agnostic core of the socket bridge: decode one `request` wire frame and return the
  response bytes by dispatching through the Membrane in the given run context (`vfs`, `perms`). A frame
  whose command is NOT a host cap yields a clear error — the socket transport is for HOST caps only;
  real programs run in the wasm shell, not here.
  """
  def handle_request(vfs, perms, request) when is_binary(request) do
    {cmd, args, stdin} = parse_frame(request)

    case dispatch(vfs, cmd, args, stdin, perms) do
      {:host, out} when is_binary(out) -> out
      {:host, out} -> to_string(out)
      :not_host -> "membrane: '#{cmd}' is not a host capability — run it in the shell, not via the bridge"
    end
  end

  @doc false
  # Parse `<cmd>\t<args…>\n<stdin>` → {cmd, [args], stdin}. A frame with no newline is all-header (no
  # stdin); an empty header yields an empty command (dispatch will report it as non-host).
  def parse_frame(request) do
    {header, stdin} =
      case :binary.split(request, "\n") do
        [h, rest] -> {h, rest}
        [h] -> {h, ""}
      end

    case String.split(header, "\t", trim: false) do
      [""] -> {"", [], stdin}
      [cmd | args] -> {cmd, args, stdin}
    end
  end
end
