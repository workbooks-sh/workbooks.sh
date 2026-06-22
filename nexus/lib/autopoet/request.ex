defmodule Nexus.Autopoet.Request do
  @moduledoc """
  A typed self-edit REQUEST an agent files to the autopoet (Autopoiesis v2 — wb-a6u3.6). When an agent
  metacognitively notices it needs a change it can't make itself, it files one of these — as a workbooks
  native to-do (the to-dos DAG = `resource Todo`, kind `"issue"`), **fire-and-forget**: it never awaits
  the autopoet, it degrades and continues. Continuity lives in the durable to-do + agent definition, not
  the ephemeral run.

  The request is **typed on purpose** — it is the injection firewall. The autopoet decides off the typed
  `change` (a delta like `"grant +net"`) plus VERIFIABLE `evidence` (a failing run id, a telemetry key, a
  red `check`), never off the free-prose `why` — which is UNTRUSTED context for a human reviewer, never an
  instruction the autopoet obeys.

      target     — "self" or an agent name (the autopoet checks the TARGET's management tag, not the filer's)
      change     — the typed delta the autopoet acts on
      why        — free prose; untrusted (informs a human; never obeyed)
      evidence   — verifiable pointers the autopoet/human can independently check
      acceptance — how success is judged (a check that should go green)

  Filing emits a neutral `self_edit.requested` event onto the bus (the runtime carries only the
  mechanism); our cloud product's hook persists it into the to-dos store. `dedup_key/1` lets the
  consumer drop refiles so ephemeral runs don't storm the backlog with the same request.
  """

  @enforce_keys [:target, :change]
  defstruct [:target, :change, :why, :evidence, :acceptance]

  @type t :: %__MODULE__{
          target: String.t(),
          change: String.t(),
          why: String.t() | nil,
          evidence: [String.t()],
          acceptance: String.t() | nil
        }

  @doc "Build a validated request. Requires `target` + `change`; the rest are optional."
  def new(attrs) when is_map(attrs) do
    with {:ok, target} <- fetch(attrs, :target),
         {:ok, change} <- fetch(attrs, :change) do
      {:ok,
       %__MODULE__{
         target: String.trim(to_string(target)),
         change: String.trim(to_string(change)),
         why: opt(attrs, :why),
         evidence: attrs |> get(:evidence) |> List.wrap() |> Enum.map(&to_string/1),
         acceptance: opt(attrs, :acceptance)
       }}
    end
  end

  @doc """
  A stable dedup key — `target :: normalized(change)`. The free-prose `why` is deliberately NOT part of
  it: two runs noticing the same need file the same key, so the consumer can dedup regardless of phrasing.
  """
  def dedup_key(%__MODULE__{target: t, change: c}), do: t <> "::" <> normalize(c)

  @doc """
  File the request fire-and-forget — emit a neutral `self_edit.requested` event onto the bus and return
  the stamped event. The agent does NOT await; the cloud product persists it into the to-dos DAG.
  """
  def file(%__MODULE__{} = r) do
    Nexus.Events.emit(%{
      kind: "self_edit.requested",
      actor: r.target,
      title: r.change,
      target: r.target,
      change: r.change,
      why: r.why,
      evidence: r.evidence,
      acceptance: r.acceptance,
      dedup_key: dedup_key(r)
    })
  end

  defp fetch(attrs, key) do
    case get(attrs, key) do
      v when is_binary(v) or is_atom(v) ->
        s = String.trim(to_string(v))
        if s == "", do: {:error, "#{key} is required"}, else: {:ok, s}

      _ ->
        {:error, "#{key} is required"}
    end
  end

  defp get(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, to_string(key))

  defp opt(attrs, key) do
    case get(attrs, key) do
      v when is_binary(v) -> String.trim(v)
      _ -> nil
    end
  end
  defp normalize(c), do: c |> String.downcase() |> String.replace(~r/\s+/, " ") |> String.trim()
end
