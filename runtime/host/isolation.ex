defmodule Workbooks.Isolation do
  @moduledoc """
  The isolation TIER ladder (wb-rhs.10) — the *depth* knob of the `(width, tier)`
  surface (width lives in Workbooks.Fabric). One source of truth for how isolated
  a toolkit/kernel call is, so the tier is SELECTABLE (pick per call), OBSERVABLE
  (see/declare which tier ran), and DEFAULTED sanely (from the `#+TRUST` posture).

  Distribution and isolation are the same primitive (see [[toolkit-isolation-model]]):
  fan-out width × containment depth. At `:node` the two merge — a peer BEAM node is
  both stronger isolation AND cross-machine scale.

  Tiers, lightest → heaviest:

    | tier        | status     | boundary       | isolates against                          |
    |-------------+------------+----------------+-------------------------------------------|
    | :instance   | live       | linear memory  | memory corruption, ungranted caps         |
    | :os_process | available  | OS process     | runaway CPU, native crash (no clean preempt yet) |
    | :node       | planned    | BEAM VM        | host-side crash/scheduler + cross-machine  |
    | :container  | planned    | OS kernel      | hostile / multi-tenant                     |

  BOTH `:instance` and `:os_process` are LIVE today — and which one a call uses is
  determined by the artifact SHAPE, not a free knob:
    * a `command` runs as a per-call subprocess wasmtime (run_wasmtime, `-W fuel`
      + `-W timeout`) → `:os_process`. (This was always true; an earlier version of
      this module mislabeled it `:available`.)
    * a `kernel`/`component` runs in a persistent in-VM Wasmex instance →
      `:instance`.
  `:node`/`:container` are defined but not yet built. Use `tier_for_shape/1` to map
  an `#+EXEC` shape to its real tier. Statuses are honest — nothing pretends a tier
  works before it does.
  """

  @tiers %{
    instance: %{
      status: :live,
      boundary: :linear_memory,
      blurb: "persistent in-VM Wasmex instance (KERNELS + components) — instantiate-once, memory-sandboxed, trap-contained, reused across calls. Fast.",
      isolates: "memory corruption, ungranted caps"
    },
    os_process: %{
      status: :live,
      boundary: :os_process,
      blurb: "per-call subprocess wasmtime (COMMANDS via run_wasmtime — -W fuel/-W timeout, hard-killable). Separate OS process; cannot corrupt the BEAM VM.",
      isolates: "runaway CPU, native-level crash"
    },
    node: %{
      status: :live,
      boundary: :beam_node,
      blurb: "peer BEAM node (:peer, Workbooks.IsolationNode) — full VM isolation AND cross-machine scale (the render farm spread across boxes). Runtime-gated: needs distribution (IsolationNode.available?).",
      isolates: "host-side crash/scheduler; distributes across machines"
    },
    container: %{
      status: :live,
      boundary: :os_kernel,
      blurb: "throwaway container (Workbooks.IsolationContainer — docker|podman, --network none + mem/cpu/pids caps + read-only) — kernel/tenancy boundary. Runtime-gated: needs the runtime + a wasmtime image (IsolationContainer.available?).",
      isolates: "hostile / multi-tenant workloads"
    }
  }

  @doc "The whole tier ladder (tier → metadata)."
  def tiers, do: @tiers

  @doc "Metadata for one tier, or nil if unknown."
  def tier(t) when is_atom(t), do: Map.get(@tiers, t)

  @doc "Is `t` a known tier name?"
  def known?(t), do: Map.has_key?(@tiers, t)

  @doc "Is `t` actually implemented (runnable) today?"
  def live?(t), do: status(t) == :live

  @doc "Status of a tier: :live | :available | :planned | :unknown."
  def status(t), do: get_in(@tiers, [t, :status]) || :unknown

  @doc """
  The default tier for a `#+TRUST` posture (TOOLKIT-MANIFEST). Trust you already
  declare picks a sane containment default; first-party stays cheap, third-party
  gets the killable boundary. Overridable per call.
  """
  def default_for_trust("third-party"), do: :node
  def default_for_trust(_first_party_or_nil), do: :instance

  @doc """
  The real isolation tier an `#+EXEC` shape runs at today (the tier is determined
  by shape, not a free per-call knob):
    * command  → :os_process  (per-call subprocess wasmtime)
    * posix    → :os_process  (native binary, separate process)
    * kernel   → :instance    (persistent in-VM Wasmex)
    * component→ :instance    (in-VM Wasmex.Components)
    * task/federation → nil    (no wasm artifact of its own)
  """
  def tier_for_shape(exec) when is_binary(exec) do
    case exec do
      "command" -> :os_process
      "posix" -> :os_process
      "kernel" -> :instance
      "component" -> :instance
      _ -> nil
    end
  end

  def tier_for_shape(_), do: nil

  @doc """
  The EFFECTIVE isolation tier a toolkit runs at, combining its `#+EXEC` shape
  default with its `#+TRUST` posture (wb-pkh.5). First-party runs at the shape
  default; third-party (untrusted supply chain) ESCALATES to the strongest live
  tier — `:node`, a separate BEAM VM — so a NIF-level crash or runaway can't touch
  the runtime. Observable: this is the tier a call SHOULD run at; the executor
  honors it where the path exists (commands today).
  """
  def effective_tier(exec, trust)
  def effective_tier(exec, "third-party"), do: escalate(tier_for_shape(exec))
  def effective_tier(exec, _first_party_or_nil), do: tier_for_shape(exec)

  # Escalate one rung toward stronger isolation, capped at the strongest LIVE tier.
  defp escalate(:instance), do: :node
  defp escalate(:os_process), do: :node
  defp escalate(:node), do: :node
  defp escalate(other), do: other

  @doc """
  Resolve a requested tier to a runnable one, or an explanatory error. Used by the
  fabric so a non-live tier fails with WHY (available-but-unwired vs planned),
  never a bare `:unsupported`.
  """
  def resolve(t) do
    case status(t) do
      :live ->
        {:ok, t}

      :planned ->
        {:error, {:tier_planned, t, "tier #{inspect(t)} is defined but not yet built — wb-rhs.10"}}

      :unknown ->
        {:error, {:unknown_tier, t, "no such isolation tier #{inspect(t)} (known: #{Enum.map_join(Map.keys(@tiers), ", ", &inspect/1)})"}}
    end
  end

  @doc "A human/agent-readable view of the ladder — so the tier is OBSERVABLE."
  def describe do
    header = "Isolation tiers (wb-rhs.10) — the containment depth of a toolkit/kernel call:\n"

    rows =
      [:instance, :os_process, :node, :container]
      |> Enum.map_join("\n", fn t ->
        m = @tiers[t]
        mark = if m.status == :live, do: "●", else: "○"
        "  #{mark} #{String.pad_trailing(to_string(t), 11)} [#{m.status}]  #{m.blurb}"
      end)

    header <> rows <> "\n\nDefault is derived from #+TRUST (first-party → instance, third-party → os_process); override per call."
  end
end
