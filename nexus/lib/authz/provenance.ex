defmodule Nexus.Authz.Provenance do
  @moduledoc """
  **Provenance tagging** for untrusted input reaching an agent's context (wb-d8ac.10).

  An agent's context is assembled from many sources: the operator's instructions (trusted), tool
  output (semi-trusted), and — critically — inbound *messages and external data* an attacker can
  control (UNtrusted). The prompt-injection risk is that untrusted text talks the agent into a
  privileged action. The defense: tag where each piece of context came from, and refuse to let a
  privileged action be *derived from* untrusted provenance without an explicit, separately-authorized
  escalation.

  This module is the bookkeeping + the gate. A provenance is a list of `{source, trust}` tags; the
  context is `untrusted?` if any tag is untrusted. `guard/2` refuses a high-tier capability
  (`Nexus.AgentGov` `:exfil`/`:execute`) when the triggering context is untrusted — the agent may
  still answer, it just cannot exfiltrate or execute on a stranger's say-so.
  """

  @trust_levels [:trusted, :tool, :untrusted]

  @doc "A fresh, empty provenance (trusted by default — nothing untrusted has entered yet)."
  def new, do: []

  @doc "Tag `provenance` with a `source` at a `trust` level (`:trusted` | `:tool` | `:untrusted`)."
  @spec tag([{atom, atom}], atom, atom) :: [{atom, atom}]
  def tag(provenance, source, trust \\ :untrusted) when trust in @trust_levels do
    [{source, trust} | provenance]
  end

  @doc "Convenience: mark that untrusted input (an inbound message, fetched page, …) entered the context."
  @spec mark_untrusted([{atom, atom}], atom) :: [{atom, atom}]
  def mark_untrusted(provenance, source), do: tag(provenance, source, :untrusted)

  @doc "Is any part of this context untrusted?"
  @spec untrusted?([{atom, atom}]) :: boolean
  def untrusted?(provenance), do: Enum.any?(provenance, fn {_s, t} -> t == :untrusted end)

  @doc "The set of sources that contributed untrusted input (for the audit trail / explanation)."
  @spec untrusted_sources([{atom, atom}]) :: [atom]
  def untrusted_sources(provenance) do
    provenance |> Enum.filter(fn {_s, t} -> t == :untrusted end) |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
  end

  @doc """
  Gate a capability use against the context's provenance. A high-tier capability (`:exfil`/`:execute`)
  derived from an untrusted context is refused — that's the prompt-injection blast-radius cut. Lower
  tiers (read/network/write) pass; pair with `Nexus.Authz.DualControl` if even those need a human.
  Returns `:ok | {:error, {:untrusted_provenance, sources}}`.
  """
  @spec guard([{atom, atom}], String.t()) :: :ok | {:error, {:untrusted_provenance, [atom]}}
  def guard(provenance, capability) when is_binary(capability) do
    high? = Nexus.AgentGov.tier(capability) in [:exfil, :execute]

    if high? and untrusted?(provenance) do
      {:error, {:untrusted_provenance, untrusted_sources(provenance)}}
    else
      :ok
    end
  end
end
