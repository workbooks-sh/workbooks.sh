defmodule Nexus.JJ do
  @moduledoc """
  The Jujutsu (jj) working layer colocated over a workspace's git repo — the
  **op-log / undo ledger**.

  jj colocates on the existing git repo (`jj git init --colocate`): same working
  copy, same commits, but jj adds an OPERATION LOG — every change to repo state
  (commit, rebase, abandon) is itself a recorded, addressable, undoable operation.
  That gives the workspace a native, replayable "what happened / undo" record that
  corroborates the git history from a second direction.

  Thin by design: we shell to `jj`, we don't reimplement it. **No-op-safe** if `jj`
  isn't on PATH — everything degrades to `{:skip, …}` / `[]`.

  ## Two roles

  1. **Corroborating ledger** (`ensure/1`, `op_entries/2`, `oplog/2`, `status/1`) —
     colocate on a normal working-dir repo and read the op-log alongside git.
  2. **Substrate** (`substrate?/0`, `ensure_colocated/2`, `commit_change/4`,
     `undo/3`) — make jj the engine for the nexus's INTERNAL commits while keeping
     the canonical **bare** repo clients push to (Option B). The working dir's `.git`
     is a gitlink to the bare; jj colocates over it; `jj git export` advances the
     bare's branch. Internal edits (dashboard saves, agent edits) routed through
     `Nexus.Git.commit_file/4` then land in the op-log and become `jj undo`-able.
     Gated by the `jj-substrate` deploy flag (default off) — off ⇒ pure git, jj
     absent ⇒ pure git. git stays the on-disk source of truth; jj is the operating layer over it.
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

  # ── jj AS THE SUBSTRATE (Option B) ─────────────────────────────────────────────────────────────
  # The nexus serves workspaces from a CANONICAL BARE repo (`repos_root/<id>.git`); the working tree is
  # ephemeral + reconstructible. To make jj the substrate WITHOUT retiring the bare, colocate jj over a
  # working dir whose `.git` is a gitlink FILE pointing at the bare (a linked worktree). jj then operates
  # on the bare's object store; `jj git export` advances the bare's branch ref, so clients pulling the
  # bare see internal edits. Proven recipe (spike): gitlink → `jj git init --colocate` → describe →
  # `jj bookmark set <branch>` → new → `jj git export`. jj 0.39 needs the explicit bookmark (not a branch).

  @doc "Is jj-as-substrate enabled (deploy flag) AND jj installed? Gates the internal-commit routing."
  def substrate? do
    available?() and config_substrate?()
  end

  defp config_substrate? do
    if function_exported?(Nexus.Config, :jj_substrate?, 0), do: Nexus.Config.jj_substrate?(), else: false
  rescue
    _ -> false
  end

  @doc """
  Colocate jj over `work_dir` whose git metadata lives in the external `bare`. Idempotent + no-op-safe.
  Writes the `.git` gitlink, points the bare at the worktree, runs colocate. `:ok | {:skip,_} | {:error,_}`.
  """
  def ensure_colocated(bare, work_dir) do
    cond do
      not available?() -> {:skip, "jj not installed"}
      File.dir?(Path.join(work_dir, ".jj")) -> :ok
      not File.dir?(bare) -> {:skip, "no bare repo at #{bare}"}
      true ->
        File.mkdir_p!(work_dir)
        # gitlink FILE → the bare (linked-worktree style); make the bare worktree-aware.
        File.write!(Path.join(work_dir, ".git"), "gitdir: #{bare}\n")
        git_bare(bare, ["config", "core.bare", "false"])
        git_bare(bare, ["config", "core.worktree", work_dir])
        jj(work_dir, ["git", "init", "--colocate"])
        jj(work_dir, ["config", "set", "--repo", "user.name", "workbooks"])
        jj(work_dir, ["config", "set", "--repo", "user.email", "engine@workbooks.local"])

        case jj(work_dir, ["status"]) do
          {_, 0} -> :ok
          {out, _} -> {:error, out}
        end
    end
  end

  @doc """
  Seal the current working-copy state as a jj commit (recording an OP-LOG entry), advance `branch` in the
  canonical `bare`, and return `{:ok, short_sha} | {:skip, reason} | {:error, out}`. This is the seam that
  makes every internal edit `jj undo`-able. `branch` defaults to "main".
  """
  def commit_change(bare, work_dir, message, branch \\ "main") do
    with :ok <- ensure_colocated(bare, work_dir),
         {_, 0} <- jj(work_dir, ["describe", "-m", message]),
         {_, 0} <- jj(work_dir, ["bookmark", "set", branch, "-r", "@", "--allow-backwards"]),
         {_, 0} <- jj(work_dir, ["new"]),
         {_, 0} <- jj(work_dir, ["git", "export"]),
         {sha, 0} <- jj(work_dir, ["log", "--no-graph", "-r", "@-", "-T", "commit_id.short()"]) do
      {:ok, String.trim(sha)}
    else
      {:skip, r} -> {:skip, r}
      {out, _code} when is_binary(out) -> {:error, out}
      other -> {:error, inspect(other)}
    end
  end

  @doc """
  Undo the latest operation (the user-facing Undo), re-pointing `branch` and re-exporting so the bare
  reverts too. `:ok | {:skip,_} | {:error,_}`.
  """
  def undo(bare, work_dir, branch \\ "main") do
    with :ok <- ensure_colocated(bare, work_dir),
         {_, 0} <- jj(work_dir, ["undo"]),
         {_, 0} <- jj(work_dir, ["bookmark", "set", branch, "-r", "@-", "--allow-backwards"]),
         {_, 0} <- jj(work_dir, ["git", "export"]) do
      :ok
    else
      {:skip, r} -> {:skip, r}
      {out, _} when is_binary(out) -> {:error, out}
      other -> {:error, inspect(other)}
    end
  end

  # jj short op ids are lowercase hex — a tight allowlist for the read-only op-log.
  defp valid_op_id?(id), do: is_binary(id) and id =~ ~r/\A[0-9a-f]{4,}\z/

  defp jj(dir, args), do: System.cmd("jj", args, cd: dir, stderr_to_stdout: true)
  defp git_bare(bare, args), do: System.cmd("git", ["--git-dir=#{bare}" | args], stderr_to_stdout: true)
end
