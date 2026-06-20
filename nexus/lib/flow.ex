defmodule Nexus.Flow do
  @moduledoc """
  The `flow` kind — a runnable, ORDERED sequence of steps (a pipeline / state machine), the composing
  half of the reactive layer. Where a `hook` reacts to an event by firing effects async, a `flow` runs
  its steps in order and threads each step's result into the next:

      flow :onboard do
        step :provision, run: "provisioner"   # runs the agent/unit on the threaded value
        step :welcome,   run: "greeter"
        step :announce,  emit: "user.onboarded"
      end

  Each step is an effect from the OPEN `Nexus.Effects` registry (`run`/`call`/`emit`/`notify`, plus any
  a consumer registers). `Nexus.Flow.run(name, input)` runs the steps in order and returns the final
  result + a per-step trace. A flow is itself runnable as an effect (`run flow: "onboard"`), so a `hook`
  can trigger one. Generic mechanism only — no Workbooks business here.
  """
  @reg {__MODULE__, :flows}

  @doc "Compile a parsed `flow` node into a spec and register it. Returns the spec."
  def compile(%{kind: "flow", name: name} = node) do
    steps = node |> Map.get(:ast) |> do_body() |> statements() |> Enum.flat_map(&step/1)
    spec = %{name: to_string(name), steps: steps}
    register(spec)
    spec
  end

  def compile(_), do: nil

  @doc "Register (or replace by name) a flow spec."
  def register(%{name: name} = spec) do
    :persistent_term.put(@reg, Map.put(all_map(), name, spec))
    :ok
  end

  @doc "All registered flow specs."
  def all, do: all_map() |> Map.values()

  @doc "A flow spec by name, or nil."
  def get(name), do: Map.get(all_map(), to_string(name))

  defp all_map, do: :persistent_term.get(@reg, %{})

  @doc """
  Run a flow by name, threading `input` through its steps in order.
  Returns `{:ok, %{result, trace}}` or `{:error, {:no_flow, name}}`.
  """
  def run(name, input, ctx \\ %{}) do
    case get(name) do
      nil ->
        {:error, {:no_flow, to_string(name)}}

      %{steps: steps} ->
        {result, trace} =
          Enum.reduce(steps, {input, []}, fn s, {acc, tr} ->
            out = run_step(s, acc, ctx)
            {thread(acc, out), [%{step: s.name, out: out} | tr]}
          end)

        {:ok, %{result: result, trace: Enum.reverse(trace)}}
    end
  end

  # a step runs one effect; the threaded value is offered as the input/task.
  defp run_step(%{effect: %{name: ename, args: args}}, acc, ctx) do
    args = Map.put_new(args, :task, to_text(acc))
    Nexus.Effects.run(%{name: ename, args: args}, %{input: acc, title: to_text(acc)}, ctx)
  end

  # thread the step's result forward when it's a usable value; else keep the accumulator.
  defp thread(_acc, {:ok, %{answer: a}}) when is_binary(a), do: a
  defp thread(_acc, out) when is_binary(out), do: out
  defp thread(acc, _out), do: acc

  defp step({:step, _, [sname, kw]}) when is_list(kw) do
    case kw do
      [{ename, val} | _] -> [%{name: to_string(sname), effect: effect_for(ename, val)}]
      _ -> []
    end
  end

  defp step(_), do: []

  defp effect_for(:run, val), do: %{name: "run", args: run_args(val)}
  defp effect_for(:call, val), do: %{name: "call", args: run_args(val)}
  defp effect_for(:emit, val), do: %{name: "emit", args: %{kind: to_string(val)}}
  defp effect_for(:notify, val), do: %{name: "notify", args: %{title: to_string(val)}}
  defp effect_for(other, val), do: %{name: to_string(other), args: %{value: val}}

  defp run_args(val) when is_binary(val), do: %{agent: val}
  defp run_args(val) when is_list(val), do: Map.new(val)
  defp run_args(val), do: %{agent: to_string(val)}

  defp to_text(v) when is_binary(v), do: v
  defp to_text(v), do: inspect(v)

  defp do_body({_kind, _meta, args}) when is_list(args) do
    case List.last(args) do
      [{:do, body}] -> body
      _ -> nil
    end
  end

  defp do_body(_), do: nil

  defp statements(nil), do: []
  defp statements({:__block__, _meta, stmts}), do: stmts
  defp statements(single), do: [single]
end
