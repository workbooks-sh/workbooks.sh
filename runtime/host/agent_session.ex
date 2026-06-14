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

  @doc "Cancel a running session — kills the run process and tells subscribers."
  def cancel(id), do: call(id, :cancel)

  @impl true
  def init({id, system, task, opts}) do
    {:ok,
     %{
       id: id,
       # Owning tenant (wb-g1yo.2) — gates who may join/cancel this session's channel.
       tenant: Keyword.get(opts, :tenant),
       status: :running,
       run: nil,
       run_pid: nil,
       live: [],
       subs: [],
       reviews: [],
       review_log: []
     }, {:continue, {:run, system, task, opts}}}
  end

  @impl true
  def handle_continue({:run, system, task, opts}, state) do
    parent = self()
    run_id = state.id

    run_pid = spawn(fn ->
      {:ok, vfs} = Workbooks.VFS.open(Keyword.get(opts, :vfs, ":memory:"))

      run =
        Workbooks.Agent.run(system, task,
          vfs: vfs,
          tenant: Keyword.get(opts, :tenant, "dev"),
          model: opts[:model],
          max_steps: Keyword.get(opts, :max_steps, 40),
          # exec is a TRUST grant forwarded from the run request: host-brokered
          # git/publish tools + OS-workdir filesystem routing. NOT native exec —
          # the `run` bash hatch was deleted (wb-9ja).
          exec: Keyword.get(opts, :exec, false),
          # WB_RUN lets the agent address its OWN run for CTK reviews — build the
          # ?run= connect URL + `wb ctk await $WB_RUN` (see toolkits/ctk).
          env: [{"WB_RUN", run_id} | Keyword.get(opts, :env, [])],
          on_step: fn ev -> send(parent, {:step, ev}) end,
          on_delta: fn chunk -> send(parent, {:delta, chunk}) end
        )

      send(parent, {:run_done, run})
    end)

    {:noreply, %{state | run_pid: run_pid}}
  end

  @impl true
  def handle_call(:cancel, _from, state) do
    if is_pid(state.run_pid) and Process.alive?(state.run_pid), do: Process.exit(state.run_pid, :kill)
    Enum.each(state.subs, &send(&1, {:agent_done, "(cancelled)"}))
    {:reply, :ok, %{state | status: :cancelled}}
  end

  @impl true
  def handle_info({:step, ev}, state) do
    Enum.each(state.subs, &send(&1, {:agent_step, ev}))
    {:noreply, %{state | live: state.live ++ [ev]}}
  end

  # Per-token text delta from the agent's LLM stream → fan out to live
  # subscribers. Not accumulated here (the final run.result carries the full
  # text); this is purely the incremental wire.
  def handle_info({:delta, chunk}, state) do
    Enum.each(state.subs, &send(&1, {:agent_delta, chunk}))
    {:noreply, state}
  end

  def handle_info({:run_done, run}, state) do
    Enum.each(state.subs, &send(&1, {:agent_done, run.result}))
    {:noreply, %{state | status: :done, run: run}}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    # Replay accumulated state to a LATE subscriber — the desktop joins
    # session:<id> just after POSTing the run, which may already have produced
    # steps (or finished). Without replay a fast run completes before the join
    # and the chat shows nothing. Past steps first, then the final result.
    Enum.each(state.live, &send(pid, {:agent_step, &1}))
    if state.run, do: send(pid, {:agent_done, state.run.result})
    {:reply, :ok, %{state | subs: [pid | state.subs]}}
  end

  # CTK human-in-the-loop review: queue it for the poller (`reviews`), keep an
  # append-only `review_log` for the run's record (surfaced in status), and push
  # to live subscribers immediately.
  def handle_call({:put_review, review}, _from, state) do
    Enum.each(state.subs, &send(&1, {:agent_review, review}))
    persist_review(state.id, review)
    {:reply, :ok,
     %{state | reviews: state.reviews ++ [review], review_log: state.review_log ++ [review]}}
  end

  # Durable record: append each approved review to a per-run JSONL so it survives
  # the run process / a restart (reproducibility), beyond the in-memory log.
  defp persist_review(id, review) do
    dir = Path.join([System.tmp_dir!(), "wb-ctk-reviews"])
    File.mkdir_p(dir)
    File.write(Path.join(dir, "#{id}.jsonl"), Jason.encode!(review) <> "\n", [:append])
  rescue
    _ -> :ok
  end

  def handle_call(:take_review, _from, %{reviews: []} = state), do: {:reply, nil, state}

  def handle_call(:take_review, _from, %{reviews: [r | rest]} = state),
    do: {:reply, r, %{state | reviews: rest}}

  def handle_call(:status, _from, %{run: nil, status: st, live: live} = state),
    do: {:reply, %{status: st, tenant: state.tenant, steps: length(live), live: live, reviews: state.review_log}, state}

  def handle_call(:status, _from, %{run: r, status: st} = state) do
    reply = %{
      status: st,
      tenant: state.tenant,
      steps: r.steps,
      result: r.result,
      tools: r.events |> Enum.map(& &1.tool) |> Enum.uniq(),
      events_org: r.log,
      reviews: state.review_log
    }

    {:reply, reply, state}
  end
end
