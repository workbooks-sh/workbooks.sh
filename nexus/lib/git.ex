defmodule Nexus.Git do
  @moduledoc """
  System-managed git for a workspace — the substrate under the Drive-like workspace
  model. A workspace directory *is* a git repo, and the engine commits changes
  mechanically, so every workspace has a full, restorable history without anyone
  touching branches or worktrees. Agents and users barely touch git verbs; the
  system does it for them.

  Thin by design: we shell to `git` (host-only). The remote/backup layer
  (GitHub-as-monorepo or our cold storage) and the signed-ledger/DID layer sit on
  top — this is the local mechanism they build on. See `Nexus.JJ` for the op-log /
  undo ledger colocated over the same repo.
  """
  @name "workbooks"
  @email "engine@workbooks.local"

  @doc "Is `dir` already a git repo?"
  def repo?(dir), do: File.dir?(Path.join(dir, ".git"))

  @doc "Idempotently make `dir` a managed git repo (with engine identity). Returns `dir`."
  def ensure(dir) do
    File.mkdir_p!(dir)

    unless repo?(dir) do
      git(dir, ["init", "-q"])
      git(dir, ["config", "user.name", @name])
      git(dir, ["config", "user.email", @email])
    end

    dir
  end

  @doc """
  Stage everything and commit. Mechanistic — the engine calls this on change.
  `{:ok, short_sha}` · `:nochange` · `{:error, output}`. Hooks are disabled so a
  global hook (e.g. a beads hook) can't touch a managed repo.
  """
  def commit(dir, message) when is_binary(message) do
    ensure(dir)
    git(dir, ["add", "-A"])

    case git(dir, ["-c", "core.hooksPath=/dev/null", "commit", "-q", "-m", message]) do
      {_, 0} ->
        {sha, _} = git(dir, ["rev-parse", "--short", "HEAD"])
        {:ok, String.trim(sha)}

      {out, _} ->
        if String.contains?(out, "nothing to commit"), do: :nochange, else: {:error, out}
    end
  end

  @doc "Recent commits, newest first: `[%{sha, message}]`."
  def log(dir, limit \\ 20) do
    if repo?(dir) do
      case git(dir, ["log", "--format=%h\t%s", "-n", to_string(limit)]) do
        {out, 0} ->
          out
          |> String.split("\n", trim: true)
          |> Enum.flat_map(fn line ->
            case String.split(line, "\t", parts: 2) do
              [sha, msg] -> [%{sha: String.trim(sha), message: String.trim(msg)}]
              [sha] -> [%{sha: String.trim(sha), message: ""}]
              _ -> []
            end
          end)

        _ ->
          []
      end
    else
      []
    end
  end

  defp git(dir, args), do: System.cmd("git", args, cd: dir, stderr_to_stdout: true)
end
