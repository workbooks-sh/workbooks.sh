defmodule Nexus.JJ do
  @moduledoc """
  The Jujutsu (jj) working layer colocated over a workspace's git repo — the
  **op-log / undo ledger**.

  jj colocates on the existing git repo (`jj git init --colocate`): same working
  copy, same commits, but jj adds an OPERATION LOG — every change to repo state
  (commit, rebase, abandon) is itself a recorded, addressable, undoable operation.
  That gives the workspace a native, replayable "what happened / undo" record that
  corroborates the git history from a second direction.

  Thin by design: we shell to `jj`, we don't reimplement it. Colocation means
  `Nexus.Git` keeps committing as it does and jj just observes + adds the op-log.
  **No-op-safe** if `jj` isn't on PATH — everything degrades to `{:skip, …}` / `[]`.
  jj stays a corroborating ledger only; the source of truth is git.
  """
  alias Nexus.Git

  @doc "Is the `jj` binary available? Everything here no-ops cleanly without it."
  def available? do
    case System.cmd("sh", ["-c", "command -v jj"], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  @doc """
  Idempotently colocate jj over the workspace's git repo (creating the git repo if
  needed). `:ok` · `{:skip, reason}` · `{:error, output}`.
  """
  def ensure(dir) do
    if not available?() do
      {:skip, "jj not installed"}
    else
      Git.ensure(dir)

      if File.dir?(Path.join(dir, ".jj")) do
        :ok
      else
        jj(dir, ["git", "init", "--colocate"])
        jj(dir, ["config", "set", "--repo", "user.name", "workbooks"])
        jj(dir, ["config", "set", "--repo", "user.email", "engine@workbooks.local"])

        case jj(dir, ["status"]) do
          {_, 0} -> :ok
          {out, _} -> {:error, out}
        end
      end
    end
  end

  @doc """
  Structured op-log — the user-facing "Undo" list, newest-first: `[%{id, description}]`.
  `id` is a short op hash (`^[0-9a-f]+$`), the only token safe to hand back to a
  restore call (re-validate it there). `[]` if jj is unavailable.
  """
  def op_entries(dir, limit \\ 20) do
    with :ok <- ensure(dir),
         {out, 0} <-
           jj(dir, [
             "op", "log", "--no-graph", "--limit", to_string(limit),
             "-T", ~s|id.short() ++ "\t" ++ description ++ "\n"|
           ]) do
      out
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn line ->
        case String.split(line, "\t", parts: 2) do
          [id, desc] -> [%{id: String.trim(id), description: String.trim(desc)}]
          _ -> []
        end
      end)
      |> Enum.filter(&valid_op_id?(&1.id))
    else
      _ -> []
    end
  end

  @doc "The op-log as plain lines (newest-first), or a one-line note if jj is unavailable."
  def oplog(dir, limit \\ 20) do
    with :ok <- ensure(dir),
         {out, 0} <-
           jj(dir, [
             "op", "log", "--no-graph", "--limit", to_string(limit),
             "-T", ~s|id.short() ++ " " ++ description ++ "\n"|
           ]) do
      String.split(out, "\n", trim: true)
    else
      {:skip, r} -> ["(jj unavailable: #{r})"]
      _ -> []
    end
  end

  @doc "Working-copy status as jj sees it."
  def status(dir) do
    with :ok <- ensure(dir), {out, 0} <- jj(dir, ["status"]) do
      String.trim(out)
    else
      {:skip, r} -> "jj unavailable: #{r}"
      _ -> "(no status)"
    end
  end

  # jj short op ids are lowercase hex — a tight allowlist for the read-only op-log.
  defp valid_op_id?(id), do: is_binary(id) and id =~ ~r/\A[0-9a-f]{4,}\z/

  defp jj(dir, args), do: System.cmd("jj", args, cd: dir, stderr_to_stdout: true)
end
