defmodule WorkCLI.Dev do
  @moduledoc """
  `work dev <dir> [out.html]` — the push-to-live loop. Watch the `.work` tree; on any change, re-weave
  the workbook (and, when a nexus is configured via `WB_RUNTIME_URL`, hot-swap the artifact into the
  running runtime for an instant live reload). The local static re-weave works offline; the nexus
  hot-swap is the richer tier layered on top — the Convex-like "edit → live" north star.

  Dependency-free: polls file mtimes (~500ms) rather than pulling a file-watcher lib, so the escript
  stays tiny. Runs until interrupted.
  """

  alias WorkCore.{Weave, Log}

  @poll_ms 500

  @doc "Watch `dir` and re-weave to `out` on every change. Blocks until interrupted."
  def watch(dir, out, opts \\ []) do
    Log.prompt("work dev #{dir} → #{out}")
    weave_once(dir, out)
    hot = hot_target()
    if hot, do: Log.step(Log.dim("hot-swap → #{hot}")), else: Log.step(Log.dim("static re-weave (set WB_RUNTIME_URL for nexus hot-swap)"))
    Log.step(Log.dim("watching #{Path.join(dir, "**/*.work")} — Ctrl-C to stop"))
    loop(dir, out, snapshot(dir), hot, Keyword.get(opts, :poll_ms, @poll_ms))
  end

  @doc "Weave once and report — the body of a watch tick (also the `--once` path, testable)."
  def weave_once(dir, out) do
    {:ok, ^out, bytes} = Weave.to_file(dir, out)
    Log.ok("wove #{Path.basename(out)}", detail: "#{Weave.unit_count(dir)} unit(s) · #{bytes} B")
    {:ok, out}
  end

  @doc "A snapshot of the tree's `.work` files → mtime (the change signal)."
  def snapshot(dir) do
    (Path.wildcard(Path.join(dir, "*.work")) ++ Path.wildcard(Path.join(dir, "**/*.work")))
    |> Enum.uniq()
    |> Map.new(fn p -> {p, mtime(p)} end)
  end

  @doc "Which files changed/added/removed between two snapshots (pure — the incremental signal)."
  def changed(prev, cur) do
    added = Map.keys(cur) -- Map.keys(prev)
    removed = Map.keys(prev) -- Map.keys(cur)
    modified = for {p, m} <- cur, Map.has_key?(prev, p) and prev[p] != m, do: p
    added ++ removed ++ modified
  end

  # ── the poll loop ────────────────────────────────────────────────────────────────────────────
  defp loop(dir, out, prev, hot, poll_ms) do
    Process.sleep(poll_ms)
    cur = snapshot(dir)
    changes = changed(prev, cur)

    if changes != [] do
      Log.prompt("work dev · #{length(changes)} change(s)")
      for f <- changes, do: Log.step(Log.path(Path.basename(f)))
      weave_once(dir, out)
      if hot, do: hot_swap(out, hot)
    end

    loop(dir, out, cur, hot, poll_ms)
  end

  defp hot_swap(out, url) do
    html = File.read!(out)

    case WorkCLI.Client.post(url <> "/dev/reload", %{html: html}, timeout: 5_000) do
      {:ok, 200, _} -> Log.ok("hot-swapped", detail: url)
      {:ok, code, _} -> Log.warn("hot-swap HTTP #{code}")
      {:error, _} -> Log.warn("hot-swap unreachable — kept the local file")
    end
  end

  defp hot_target, do: System.get_env("WB_RUNTIME_URL")

  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: m}} -> m
      _ -> 0
    end
  end
end
