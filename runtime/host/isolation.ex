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

  `:instance` is live and the default. `:os_process` is *available* — the
  machinery already exists (proc_macro_host runs CLI wasmtime as a subprocess with
  a hard-kill watchdog) and is wireable into the fabric. `:node`/`:container` are
  defined but not yet built. Statuses are honest on purpose — nothing here pretends
  a tier works before it does.
  """

  @tiers %{
    instance: %{
      status: :live,
      boundary: :linear_memory,
      blurb: "wasm instance, same BEAM VM — memory-sandboxed, trap-contained, caps-gated. Fast + cheap.",
      isolates: "memory corruption, ungranted caps"
    },
    os_process: %{
      status: :available,
      boundary: :os_process,
      blurb: "separate OS process (CLI wasmtime + hard-kill watchdog) — hard CPU preempt + native-crash containment.",
      isolates: "runaway CPU, native-level crash"
    },
    node: %{
      status: :planned,
      boundary: :beam_node,
      blurb: "peer BEAM node (:peer) — full VM isolation AND cross-machine scale (the render farm spread across boxes).",
      isolates: "host-side crash/scheduler; distributes across machines"
    },
    container: %{
      status: :planned,
      boundary: :os_kernel,
      blurb: "separate container (krunvm|podman) — kernel/tenancy boundary.",
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
  def default_for_trust("third-party"), do: :os_process
  def default_for_trust(_first_party_or_nil), do: :instance

  @doc """
  Resolve a requested tier to a runnable one, or an explanatory error. Used by the
  fabric so a non-live tier fails with WHY (available-but-unwired vs planned),
  never a bare `:unsupported`.
  """
  def resolve(t) do
    case status(t) do
      :live ->
        {:ok, t}

      :available ->
        {:error, {:tier_not_wired, t, "tier #{inspect(t)} is available (machinery exists) but not yet wired into the fabric — wb-rhs.10"}}

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
