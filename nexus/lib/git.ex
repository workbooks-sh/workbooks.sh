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

  # ── Remote: the nexus AS a git remote (push-to-deploy a workspace) ───────────────────────────────
  # A workspace is a BARE repo on the nexus that you `git push` to. A `post-receive` hook checks the
  # pushed default branch out into the workspace's working dir (`work_dir`), so the files land on the
  # volume — `/cloud/tree` (which reads disk live) shows them immediately. Recompiling changed units
  # (re-mount) is a separate, additive step layered on top. Auth + the smart-HTTP transport sit above
  # this; this is the local substrate.

  @doc "Path of a workspace's bare repo under `repos_root` (e.g. WB_DATA/.nexus/repos/<name>.git)."
  def bare_path(repos_root, name), do: Path.join(repos_root, name <> ".git")

  @doc "Is `bare` an initialized bare repo?"
  def bare?(bare), do: File.regular?(Path.join(bare, "HEAD")) and File.dir?(Path.join(bare, "objects"))

  @doc """
  Provision (idempotently) a bare repo at `bare` whose `post-receive` hook checks the pushed default
  branch out into `work_dir`. Creates both dirs. Returns `{:ok, bare}`.
  """
  def provision_remote(bare, work_dir) do
    File.mkdir_p!(bare)
    File.mkdir_p!(work_dir)
    unless bare?(bare), do: System.cmd("git", ["init", "--bare", "-q", "-b", "main", bare], stderr_to_stdout: true)

    hooks = Path.join(bare, "hooks")
    # A global `core.hooksPath` (this project sets one) would shadow the bare repo's own hooks — pin it
    # to this repo's hooks dir so post-receive actually fires.
    System.cmd("git", ["--git-dir=#{bare}", "config", "core.hooksPath", hooks], stderr_to_stdout: true)

    hook = Path.join(hooks, "post-receive")
    File.write!(hook, post_receive(bare, work_dir))
    File.chmod!(hook, 0o755)
    {:ok, bare}
  end

  @doc "Check the current default branch of a bare repo out into `work_dir` (used after a push / on boot)."
  def checkout_into(bare, work_dir, branch \\ "main") do
    File.mkdir_p!(work_dir)
    System.cmd("git", ["--git-dir=#{bare}", "--work-tree=#{work_dir}", "-c", "core.bare=false",
                       "checkout", "-f", branch], stderr_to_stdout: true)
  end

  defp post_receive(bare, work_dir) do
    """
    #!/bin/sh
    # Workbooks push-to-deploy: check the pushed default branch out into the workspace working tree.
    # Clear the git env the push injects (GIT_DIR / quarantine / index) so our checkout isn't polluted.
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_QUARANTINE_PATH GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
    while read _old _new ref; do
      case "$ref" in
        refs/heads/main|refs/heads/master)
          branch="${ref#refs/heads/}"
          git --git-dir="#{bare}" --work-tree="#{work_dir}" -c core.bare=false checkout -f "$branch"
          echo "workbooks: checked out $branch into #{work_dir}"
          ;;
      esac
    done
    """
  end
end
