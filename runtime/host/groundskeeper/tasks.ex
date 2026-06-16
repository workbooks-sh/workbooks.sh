defmodule Workbooks.Groundskeeper.Tasks do
  @moduledoc """
  The groundskeeper's task ledger — the list of background workflows the voice
  agent has dispatched, visible two ways: this GenServer (the API the /gk
  routes read) and a rendered `TASKS.md` in the groundskeeper home (the
  git-visible, human/Claude-readable view; regenerated on every change, never
  hand-edited).

  Completions also queue as FEEDBACK the agent drains on its next `tasks`
  call — that is the loop back into the conversation.

  Runs are supervised + time-bounded (the autopoet lesson): a crash or timeout
  becomes status=blocked with the reason, never a stuck `doing`.
  """
  use GenServer

  @timeout_ms 35 * 60 * 1000

  defstruct tasks: %{}, feedback: [], monitors: %{}

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Record a dispatched workflow. Returns the task map (id, goal, file, status)."
  def add(goal, file), do: GenServer.call(__MODULE__, {:add, goal, file})

  @doc "Run `fun` async under supervision, bound to the ledger entry `id`."
  def run_async(id, fun), do: GenServer.call(__MODULE__, {:run, id, fun})

  def list, do: GenServer.call(__MODULE__, :list)

  @doc "Unread completion notices, oldest first; reading clears the queue."
  def drain_feedback, do: GenServer.call(__MODULE__, :drain_feedback)

  @impl true
  def init(_) do
    reset_orphans()
    {:ok, %__MODULE__{}}
  end

  # The autopoet lesson (wb-3ojf.7): the ledger is in-memory, so a restart
  # orphans any TODO/DOING entry in the rendered TASKS.md — un-pickable and
  # lying about liveness. On boot, rewrite stale active states to BLOCKED in
  # place (we own the generated file; this is a render correction, not sync).
  defp reset_orphans do
    path = Path.join(Workbooks.Groundskeeper.home(), "TASKS.md")

    with {:ok, content} <- File.read(path) do
      fixed = Regex.replace(~r/^### (DOING|TODO) /m, content, "### BLOCKED ")
      if fixed != content, do: File.write!(path, fixed)
    end

    :ok
  rescue
    _ -> :ok
  end

  @impl true
  def handle_call({:add, goal, file}, _from, s) do
    id = "gk-#{System.unique_integer([:positive])}"

    task = %{
      id: id,
      goal: goal,
      file: file,
      status: "queued",
      started: now(),
      finished: nil,
      result: nil
    }

    s = put_task(s, task)
    {:reply, task, s}
  end

  def handle_call({:run, id, fun}, _from, s) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        result =
          try do
            {:ok, fun.()}
          catch
            kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
          end

        send(parent, {:finished, id, result})
      end)

    Process.send_after(self(), {:timeout, id, pid}, @timeout_ms)
    s = update_task(s, id, %{status: "doing"})
    {:reply, :ok, %{s | monitors: Map.put(s.monitors, ref, id)}}
  end

  def handle_call(:list, _from, s) do
    {:reply, s.tasks |> Map.values() |> Enum.sort_by(& &1.started, :desc), s}
  end

  def handle_call(:drain_feedback, _from, s) do
    {:reply, Enum.reverse(s.feedback), %{s | feedback: []}}
  end

  @impl true
  def handle_info({:finished, id, result}, s) do
    {status, summary} =
      case result do
        {:ok, %{tasks: tasks}} ->
          states = Enum.frequencies_by(tasks, & &1.state)
          {"done", "workflow finished: #{inspect(states)}"}

        {:ok, other} ->
          {"done", String.slice(inspect(other), 0, 300)}

        {:error, err} ->
          {"blocked", String.slice(err, 0, 300)}
      end

    s = update_task(s, id, %{status: status, finished: now(), result: summary})
    note = %{task: id, status: status, summary: summary, goal: get_in(s.tasks, [id, :goal])}
    {:noreply, %{s | feedback: [note | s.feedback]}}
  end

  # Crash without a :finished message (kill/exit) → blocked, retryable.
  def handle_info({:DOWN, ref, :process, _pid, reason}, s) do
    case Map.pop(s.monitors, ref) do
      {nil, _} ->
        {:noreply, s}

      {id, monitors} ->
        s = %{s | monitors: monitors}

        if get_in(s.tasks, [id, :status]) == "doing" and reason != :normal do
          s = update_task(s, id, %{status: "blocked", finished: now(), result: "crashed: #{inspect(reason)}"})
          {:noreply, %{s | feedback: [%{task: id, status: "blocked", summary: inspect(reason)} | s.feedback]}}
        else
          {:noreply, s}
        end
    end
  end

  def handle_info({:timeout, id, pid}, s) do
    if get_in(s.tasks, [id, :status]) == "doing" do
      Process.exit(pid, :kill)
      s = update_task(s, id, %{status: "blocked", finished: now(), result: "timed out after #{div(@timeout_ms, 60_000)}m"})
      {:noreply, %{s | feedback: [%{task: id, status: "blocked", summary: "timeout"} | s.feedback]}}
    else
      {:noreply, s}
    end
  end

  def handle_info(_, s), do: {:noreply, s}

  # ── ledger rendering ─────────────────────────────────────────────────────────

  defp put_task(s, task) do
    s = %{s | tasks: Map.put(s.tasks, task.id, task)}
    render(s)
    s
  end

  defp update_task(s, id, attrs) do
    case s.tasks[id] do
      nil -> s
      task -> put_task(s, Map.merge(task, attrs))
    end
  end

  # TASKS.md: generated FROM this ledger, never hand-edited (no two-way sync).
  defp render(s) do
    state_kw = %{"queued" => "TODO", "doing" => "DOING", "done" => "DONE", "blocked" => "BLOCKED"}

    body =
      s.tasks
      |> Map.values()
      |> Enum.sort_by(& &1.started, :desc)
      |> Enum.map(fn t ->
        """
        ### #{state_kw[t.status] || "TODO"} #{t.goal}

        - id: #{t.id}
        - file: #{t.file}
        - started: #{t.started}#{if t.finished, do: "\n- finished: #{t.finished}", else: ""}#{if t.result, do: "\n\n#{t.result}", else: ""}
        """
      end)
      |> Enum.join("\n")

    home = Workbooks.Groundskeeper.home()
    File.mkdir_p!(home)
    File.write!(Path.join(home, "TASKS.md"), "# groundskeeper — dispatched tasks\n\nStates: TODO · DOING · BLOCKED | DONE\n\n" <> body)
  rescue
    _ -> :ok
  end

  defp now, do: Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d %H:%M:%S")
end
