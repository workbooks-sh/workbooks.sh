defmodule Workbooks.MonorepoWatcher do
  @moduledoc """
  Workspace file-change firehose (wb-kbq5.4) over `monorepo:watch`. The desktop
  sets its workspace folders via `workspace:control` `set_scope`; this GenServer
  polls those folders (no FS-watch dep in-tree) and pushes a `file_changed`
  event per created/modified/removed file to the joined shells.

  Polling, not inotify — the in-app write surfaces (board PATCH etc.) already
  refresh directly, so this only needs to catch EXTERNAL edits, where a few-second
  latency is fine. Heavy dirs are excluded and the file set is capped so a big
  workspace can't make each tick expensive.
  """
  use GenServer

  @registry Workbooks.MonorepoWatch.Registry
  @topic "monorepo:watch"
  @poll_ms 3_000
  @max_files 8_000
  @skip ~w(node_modules .git _build deps target .next dist build .campaign)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc "The desktop's set_scope arrived — watch these folders (resets the baseline)."
  def set_scope(folders) when is_list(folders), do: GenServer.cast(__MODULE__, {:set_scope, folders})
  def set_scope(_), do: :ok

  @doc "A shell joined monorepo:watch — remember it for fan-out."
  def register(join_ref) do
    Registry.unregister(@registry, :subs)
    Registry.register(@registry, :subs, join_ref)
  end

  @impl true
  def init(_) do
    schedule()
    {:ok, %{folders: [], mtimes: %{}}}
  end

  @impl true
  def handle_cast({:set_scope, folders}, state) do
    # Baseline the new scope so flipping scope doesn't flood every file as "new".
    {:noreply, %{state | folders: folders, mtimes: scan(folders)}}
  end

  @impl true
  def handle_info(:poll, %{folders: [], mtimes: _} = state) do
    schedule()
    {:noreply, state}
  end

  def handle_info(:poll, %{folders: folders, mtimes: old} = state) do
    new = scan(folders)

    for {path, mt} <- new, Map.get(old, path) != mt do
      push(path, if(Map.has_key?(old, path), do: "modified", else: "created"))
    end

    for {path, _} <- old, not Map.has_key?(new, path), do: push(path, "removed")

    schedule()
    {:noreply, %{state | mtimes: new}}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp schedule, do: Process.send_after(self(), :poll, @poll_ms)

  # path → mtime (epoch seconds), bounded + skipping heavy dirs.
  defp scan(folders) do
    folders
    |> Enum.flat_map(&list_files/1)
    |> Enum.take(@max_files)
    |> Map.new(fn p -> {p, mtime(p)} end)
  rescue
    _ -> %{}
  end

  defp list_files(folder) do
    if File.dir?(folder) do
      Path.wildcard(Path.join(folder, "**"))
      |> Enum.reject(fn p -> File.dir?(p) or skip?(p) end)
    else
      []
    end
  rescue
    _ -> []
  end

  defp skip?(path) do
    parts = Path.split(path)
    Enum.any?(@skip, &(&1 in parts))
  end

  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: m}} -> m
      _ -> 0
    end
  end

  defp push(path, kind) do
    payload = %{"path" => path, "op" => "fs_changed", "kind" => kind}

    Registry.dispatch(@registry, :subs, fn entries ->
      for {pid, join_ref} <- entries do
        send(pid, {:channel_push, join_ref, @topic, "file_changed", payload})
      end
    end)
  end
end
