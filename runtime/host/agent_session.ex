defmodule Workbooks.AgentSession do
  @moduledoc """
  A long-horizon agent run as a supervised background process — an HTTP caller
  starts it and returns immediately, then polls (`GET /api/run/:id`) or streams
  (`GET /api/run/:id/stream`, WS) while the agent works for minutes. The same path
  runs locally and in the deployed engine (Fly).

  The agent runs in a spawned process so the session stays responsive mid-run; it
  emits each tool step (`on_step`) back to the session, which fans it out to WS
  subscribers (live telemetry, brandnana-style) and accumulates it. The run's own
  VFS holds its state (resumable, Litestream-replicable); events.org is the trace.
  """
  use GenServer

  def start(id, system, task, opts \\ []) do
    DynamicSupervisor.start_child(__MODULE__.Sup, {__MODULE__, {id, system, task, opts}})
  end

  @doc "Run status → %{status, steps, result, tools, events_org} | :not_found."
  def status(id), do: call(id, :status)

  @doc "Subscribe the calling process to live `{:agent_step, ev}` / `{:agent_done, result}` messages."
  def subscribe(id), do: call(id, {:subscribe, self()})

  @doc "Deliver a human-in-the-loop CTK review (a `ctk.commit` event) to this run."
  def put_review(id, review), do: call(id, {:put_review, review})

  @doc "Pop the oldest pending CTK review for this run (FIFO), or nil. The agent polls this."
  def take_review(id), do: call(id, :take_review)

  defp call(id, msg) do
    case Registry.lookup(__MODULE__.Registry, id) do
      [{pid, _}] -> GenServer.call(pid, msg)
      [] -> :not_found
    end
  end

  def start_link({id, _, _, _} = spec), do: GenServer.start_link(__MODULE__, spec, name: via(id))
  defp via(id), do: {:via, Registry, {__MODULE__.Registry, id}}

  @impl true
  def init({id, system, task, opts}) do
    {:ok, %{id: id, status: :running, run: nil, live: [], subs: [], reviews: []},
     {:continue, {:run, system, task, opts}}}
  end

  @impl true
  def handle_continue({:run, system, task, opts}, state) do
    parent = self()

    spawn(fn ->
      {:ok, vfs} = Workbooks.VFS.open(Keyword.get(opts, :vfs, ":memory:"))

      run =
        Workbooks.Agent.run(system, task,
          vfs: vfs,
          tenant: Keyword.get(opts, :tenant, "dev"),
          model: opts[:model],
          max_steps: Keyword.get(opts, :max_steps, 40),
          on_step: fn ev -> send(parent, {:step, ev}) end
        )

      send(parent, {:run_done, run})
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:step, ev}, state) do
    Enum.each(state.subs, &send(&1, {:agent_step, ev}))
    {:noreply, %{state | live: state.live ++ [ev]}}
  end

  def handle_info({:run_done, run}, state) do
    Enum.each(state.subs, &send(&1, {:agent_done, run.result}))
    {:noreply, %{state | status: :done, run: run}}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subs: [pid | state.subs]}}
  end

  # CTK human-in-the-loop review: store it + push to live subscribers immediately.
  def handle_call({:put_review, review}, _from, state) do
    Enum.each(state.subs, &send(&1, {:agent_review, review}))
    {:reply, :ok, %{state | reviews: state.reviews ++ [review]}}
  end

  def handle_call(:take_review, _from, %{reviews: []} = state), do: {:reply, nil, state}

  def handle_call(:take_review, _from, %{reviews: [r | rest]} = state),
    do: {:reply, r, %{state | reviews: rest}}

  def handle_call(:status, _from, %{run: nil, status: st, live: live} = state),
    do: {:reply, %{status: st, steps: length(live), live: live}, state}

  def handle_call(:status, _from, %{run: r, status: st} = state) do
    reply = %{
      status: st,
      steps: r.steps,
      result: r.result,
      tools: r.events |> Enum.map(& &1.tool) |> Enum.uniq(),
      events_org: r.log
    }

    {:reply, reply, state}
  end
end
