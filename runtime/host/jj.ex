defmodule Workbooks.JJ do
  @moduledoc """
  The JJ (Jujutsu) working layer over a tenant's git repo (Phase 2 — the working
  layer the identity plan takes seriously).

  JJ colocates ON the existing git repo (`jj git init --colocate`): same working
  copy, same commits, but JJ adds an OPERATION LOG — every change to the repo
  state (commit, rebase, abandon) is itself a recorded, addressable, undoable
  operation. Two things that buys the ledger:

    * the op-log REINFORCES the signed ledger — it's a second, native record of
      who-changed-what-when, replayable, so the ledger's hash-chain and JJ's
      op-log corroborate each other (tamper-evident from two directions);
    * it's the substrate for concurrent sub-agents — each works on its own JJ
      change, JJ auto-rebases the TEXT, and the org-mode validations arbitrate
      the MEANING (docs/IDENTITY-GIT-MONOREPO.md "Validation-gated merges").

  Thin by design: we shell to `jj`, we don't reimplement it. Colocation means
  nothing else has to change — `Workbooks.Git` keeps committing as it does; JJ
  just observes + adds the op-log. No-op-safe if `jj` isn't on PATH.
  """
  alias Workbooks.Git

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
  Idempotently colocate JJ on the tenant's git repo. Requires the git repo to
  exist (creates it via `ensure_repo`). Returns `:ok`, `{:skip, reason}`, or
  `{:error, out}`.
  """
  def ensure(tenant) do
    cond do
      not available?() -> {:skip, "jj not installed"}
      true ->
        dir = Git.ensure_repo(tenant)

        if File.dir?(Path.join(dir, ".jj")) do
          :ok
        else
          # Colocate over the existing git repo, and give jj an identity so
          # commit-producing ops don't fail in a headless engine.
          jj(dir, ["git", "init", "--colocate"])
          jj(dir, ["config", "set", "--repo", "user.name", "workbooks-agent"])
          jj(dir, ["config", "set", "--repo", "user.email", "#{tenant}@workbooks.local"])

          case jj(dir, ["status"]) do
            {_, 0} -> :ok
            {out, _} -> {:error, out}
          end
        end
    end
  end

  @doc "The operation log — JJ's replayable record of every repo-state change (newest first)."
  def oplog(tenant, limit \\ 20) do
    with :ok <- ensure(tenant),
         {out, 0} <- jj(repo(tenant), ["op", "log", "--no-graph", "--limit", to_string(limit),
                                       "-T", ~s|id.short() ++ " " ++ description ++ "\n"|]) do
      out |> String.split("\n", trim: true)
    else
      {:skip, r} -> ["(jj unavailable: #{r})"]
      _ -> []
    end
  end

  @doc "Working-copy status (what JJ sees as changed)."
  def status(tenant) do
    with :ok <- ensure(tenant), {out, 0} <- jj(repo(tenant), ["status"]) do
      String.trim(out)
    else
      {:skip, r} -> "jj unavailable: #{r}"
      _ -> "(no status)"
    end
  end

  @doc """
  Structured op-log: the user-facing "Undo" list. Each entry is the substrate for
  one undoable step. Returns `[%{id, description}]` newest-first, or `[]`.

  `id` is a short op hash (`^[0-9a-f]+$`) — the ONLY token the client may hand back
  to `restore_to/2`, and it is re-validated against this list there.
  """
  def op_entries(tenant, limit \\ 20) do
    with :ok <- ensure(tenant),
         {out, 0} <-
           jj(repo(tenant), [
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

  # jj short op ids are lowercase hex. Tight allowlist for the op-log reader; the
  # op-log is read-only here — user-facing Undo rides the git-level append-only
  # Restore (see `Workbooks.History.undo/2`), NOT jj, so it works identically with
  # or without jj and can never erase. jj stays a corroborating ledger only.
  defp valid_op_id?(id), do: is_binary(id) and id =~ ~r/\A[0-9a-f]{4,}\z/

  defp repo(tenant), do: Git.repo_path(tenant)

  defp jj(dir, args), do: System.cmd("jj", args, cd: dir, stderr_to_stdout: true)
end
