defmodule Workbooks.Acp do
  @moduledoc """
  Connection state + agent-index injection for the EXPERIMENTAL `acp` toolkit (the
  local-microVM coding-agent orchestrator, wb-xiei.8). See `runtime/acp-local/`.

  The `acp` toolkit is a connection-aware DEFAULT: when the ACP surface is available
  here (`Workbooks.Harness.enabled?/0` — experimental `WB_ACP_EXPERIMENTAL` AND a host
  context like `WB_DESKTOP`; off in plain dev/test and in production-cloud), the
  toolkit is injected into the agent's toolkit index with a LIVE connection state:

    * connected coding agents present -> it's a ready default ("run codex/claude in a
      microVM");
    * none connected -> it's still listed, but the copy says "no coding agents
      connected yet — connect one in the desktop to enable" (the agent then knows to
      tell the user rather than fail);
    * NOT experimental (production) -> absent entirely.

  Connected agents are reported via `WB_ACP_AGENTS` (a comma/space list, e.g.
  "codex claude"), which the desktop sets when an agent is connected (Settings →
  Integrations / onboarding). Until that desktop wiring lands the list is empty and
  the toolkit shows the "connect one" copy — the correct state.
  """

  @doc """
  True when the ACP surface is available here: the harness gate
  (`Workbooks.Harness.enabled?/0` = experimental AND a host context — `WB_DESKTOP` /
  `WB_HARNESS` / multi-tenant). So the `acp` toolkit appears only where the
  microVM orchestrator can actually run (the desktop), never in a plain dev/test or
  production-cloud runtime.
  """
  def available?, do: Workbooks.Harness.enabled?()

  @doc """
  The coding agents connected for this runtime (e.g. `["codex"]`). Empty unless the
  ACP surface is available here. Source: `WB_ACP_AGENTS`.
  """
  def connected_agents do
    if available?() do
      (System.get_env("WB_ACP_AGENTS") || "")
      |> String.split(~r/[,\s]+/, trim: true)
      |> Enum.uniq()
    else
      []
    end
  end

  @doc """
  Agent-toolkit-index row(s) for `acp` — connection-aware. `[]` unless the surface is
  available here (so the toolkit is absent from the index in plain dev/test and in
  production). Appended by `Workbooks.Toolkits.injection_text/2`.
  """
  def injection_rows do
    if available?() do
      case connected_agents() do
        [] ->
          ["- acp (experimental): run a coding agent in an isolated local microVM against the current worktree. No coding agents connected yet — connect Codex or Claude Code in the desktop to enable, then this becomes available.\n  skills: overview, run-agent"]

        agents ->
          ["- acp (experimental): run a connected coding agent (#{Enum.join(agents, ", ")}) in an isolated local microVM against the current worktree.\n  skills: overview, run-agent"]
      end
    else
      []
    end
  end
end
