defmodule Nexus.AgentGov do
  @moduledoc """
  **Agent governance** — per-agent privilege budgets and provable blast radius (wb-d8ac.7, .8).

  The differentiator nobody else can claim: because the same capability gate that bounds human code
  also bounds an *agent's* tools, we can state an agent's **maximum blast radius before it runs** — no
  RBAC-only chat platform can. This module turns that architectural fact into an enforced contract.

    * **Budget (`.8`)** — an agent's privilege budget is the capability set it is *allowed* to draw
      from: its persisted grants (`Nexus.Authz.Grants`) intersected with the grantable catalog
      (`Nexus.Capabilities`). `within_budget?/3` clamps any requested capability set to the budget, so
      a prompt-injected agent can never exercise a capability it was never granted — the budget is the
      ceiling, enforced, not advisory.

    * **Blast radius (`.7`)** — `blast_radius/1` reports the provable worst case for a capability set:
      its highest danger tier, whether it can mutate/destroy, and whether it touches secrets or runs
      code. `assurance/2` is the sellable artifact — a least-privilege statement an operator (or a
      buyer's security team) can read: "this agent can, at most, do X."

  Capabilities are classified into danger tiers so the report is meaningful rather than a flat list:

      :exfil   — secrets        (can read credentials)
      :execute — exec, commands, parallel  (can run code / shell)
      :write   — fs, vfs, kv, queue, encode (can mutate state)
      :network — net, browse, tcp, udp, tls, llm  (can reach off-box)
      :read    — everything else / posix          (read-only-ish)
  """

  @tiers %{
    "secrets" => :exfil,
    "exec" => :execute,
    "commands" => :execute,
    "parallel" => :execute,
    "fs" => :write,
    "vfs" => :write,
    "kv" => :write,
    "queue" => :write,
    "encode" => :write,
    "net" => :network,
    "browse" => :network,
    "tcp" => :network,
    "udp" => :network,
    "tls" => :network,
    "llm" => :network,
    "posix" => :read
  }

  # Most-dangerous-first, for picking the ceiling tier of a set.
  @order [:exfil, :execute, :write, :network, :read]

  @doc "The danger tier of a single capability (`:read` for anything unclassified)."
  @spec tier(String.t()) :: atom
  def tier(cap), do: Map.get(@tiers, cap, :read)

  @doc """
  The privilege BUDGET for `agent` in `org`: the capabilities it currently, durably holds — its live
  grants (honoring expiry) intersected with the grantable catalog. Optionally union `declared` caps
  (what the agent's `.work` block asks for) so a not-yet-granted agent still reports its intended
  ceiling. This is the set the agent may draw from; nothing outside it is reachable.
  """
  @spec budget(String.t(), String.t(), [String.t()]) :: [String.t()]
  def budget(org, agent, declared \\ []) when is_binary(org) and is_binary(agent) do
    granted =
      org
      |> Nexus.Authz.Grants.grants_for(agent)
      |> Enum.map(& &1[:capability])

    (granted ++ declared)
    |> Enum.filter(&Nexus.Capabilities.grantable?/1)
    |> Enum.uniq()
  end

  @doc """
  Clamp a `requested` capability set to the agent's `budget` — returns `{allowed, denied}`. The
  runtime grants only `allowed`; `denied` is what the agent asked for but is not budgeted to have
  (the audit trail of an over-reach attempt). Pure over the budget list so it's trivially testable.
  """
  @spec clamp([String.t()], [String.t()]) :: {[String.t()], [String.t()]}
  def clamp(requested, budget) do
    set = MapSet.new(budget)
    Enum.split_with(requested, &MapSet.member?(set, &1))
  end

  @doc "Is every requested capability within the agent's budget? (no over-reach)."
  @spec within_budget?(String.t(), String.t(), [String.t()]) :: boolean
  def within_budget?(org, agent, requested) do
    {_allowed, denied} = clamp(requested, budget(org, agent))
    denied == []
  end

  @doc """
  The provable blast radius of a capability set: `%{tier:, destructive?:, reads_secrets?:, executes?:,
  network?:, capabilities:}`. `tier` is the most-dangerous tier present (`:none` for an empty set).
  This is the worst case — what the agent could do if fully compromised — computed from the set
  alone, no execution required.
  """
  @spec blast_radius([String.t()]) :: map
  def blast_radius(caps) do
    tiers = caps |> Enum.map(&tier/1) |> MapSet.new()
    top = Enum.find(@order, :none, &MapSet.member?(tiers, &1))

    %{
      tier: top,
      capabilities: Enum.sort(caps),
      reads_secrets?: MapSet.member?(tiers, :exfil),
      executes?: MapSet.member?(tiers, :execute),
      destructive?: MapSet.member?(tiers, :execute) or MapSet.member?(tiers, :write),
      network?: MapSet.member?(tiers, :network)
    }
  end

  @doc """
  The least-privilege ASSURANCE for `agent` in `org` — the human/auditor-facing statement of its
  maximum authority: its budget, the blast radius of that budget, and a one-line summary. This is the
  artifact a security team reads to accept the agent (`.7`).
  """
  @spec assurance(String.t(), String.t(), [String.t()]) :: map
  def assurance(org, agent, declared \\ []) do
    b = budget(org, agent, declared)
    radius = blast_radius(b)

    %{
      agent: agent,
      budget: b,
      blast_radius: radius,
      summary: summarize(agent, radius)
    }
  end

  defp summarize(agent, %{tier: :none}), do: "#{agent} holds no capabilities — it can only read what is passed to it."

  defp summarize(agent, r) do
    verbs =
      [
        r.reads_secrets? && "read secrets",
        r.executes? && "execute code",
        r.destructive? && "mutate state",
        r.network? && "reach the network"
      ]
      |> Enum.filter(& &1)

    case verbs do
      [] -> "#{agent} can, at most, perform read-only actions."
      vs -> "#{agent} can, at most, #{Enum.join(vs, ", ")} — and nothing beyond its #{length(r.capabilities)} budgeted capabilities."
    end
  end
end
