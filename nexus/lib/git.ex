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
    maybe_colocate(bare, work_dir)
    {:ok, bare}
  end

  @doc """
  Best-effort jj colocation for a workspace when jj-as-substrate is enabled (deploy flag + jj installed).
  No-op (`:skip`) otherwise. Called at every point the working tree comes into existence (provision,
  checkout, boot rehydrate) so each workspace carries a jj op-log + `jj undo`. Never raises.
  """
  def maybe_colocate(bare, work_dir) do
    if Nexus.JJ.substrate?(), do: Nexus.JJ.ensure_colocated(bare, work_dir), else: :skip
  rescue
    _ -> :skip
  end

  @doc """
  Commit a working-tree edit into a bare repo (the dashboard edits a file directly on the volume, then
  saves it as a commit — no external push). Stages `rel_path` from `work_dir` against `bare` and commits;
  if a `workbooks.mirror` remote is set, mirrors after (post-receive only fires on receive-pack, not on
  a server-side commit, so we mirror here too). `{:ok, short_sha}` | `:nochange` | `{:error, output}`.
  """
  def commit_file(bare, work_dir, rel_path, message, opts \\ []) when is_binary(message) do
    # jj-as-substrate: when enabled (deploy flag + jj installed), route the commit through jj so it lands
    # in the op-log and is `jj undo`-able; jj exports the new ref into the bare so it stays canonical.
    # No-op-safe: off / jj-absent / any jj error falls through to the raw-git path (unchanged behavior).
    # `opts[:author]` ("Name <email>") attributes the commit to the user/agent who made the change.
    with true <- Nexus.JJ.substrate?(),
         {:ok, sha} <- Nexus.JJ.commit_change(bare, work_dir, message, opts) do
      mirror_if_configured(bare)
      {:ok, sha}
    else
      _ -> commit_file_git(bare, work_dir, rel_path, message, opts)
    end
  end

  # The raw-git internal-commit path (bare + --work-tree): the original mechanism, also the fallback when
  # jj-as-substrate is off or unavailable. Honors `opts[:author]` so attribution holds either way.
  defp commit_file_git(bare, work_dir, rel_path, message, opts) do
    base = ["--git-dir=#{bare}", "--work-tree=#{work_dir}", "-c", "core.bare=false"]
    System.cmd("git", base ++ ["add", "--", rel_path], stderr_to_stdout: true)

    author_args =
      case Keyword.get(opts, :author) do
        a when is_binary(a) and a != "" -> ["--author", a]
        _ -> []
      end

    case System.cmd("git", base ++ ["-c", "core.hooksPath=/dev/null", "commit", "-q", "-m", message] ++ author_args, stderr_to_stdout: true) do
      {_, 0} ->
        {sha, _} = System.cmd("git", ["--git-dir=#{bare}", "rev-parse", "--short", "HEAD"], stderr_to_stdout: true)
        mirror_if_configured(bare)
        {:ok, String.trim(sha)}

      {out, _} ->
        if String.contains?(out, "nothing to commit"), do: :nochange, else: {:error, out}
    end
  end

  defp mirror_if_configured(bare) do
    case System.cmd("git", ["--git-dir=#{bare}", "config", "--get", "workbooks.mirror"], stderr_to_stdout: true) do
      {url, 0} when byte_size(url) > 1 ->
        System.cmd("git", ["--git-dir=#{bare}", "push", "--mirror", String.trim(url)], stderr_to_stdout: true)
        :ok

      _ ->
        :ok
    end
  end

  @doc "Check the current default branch of a bare repo out into `work_dir` (used after a push / on boot)."
  def checkout_into(bare, work_dir, branch \\ "main") do
    File.mkdir_p!(work_dir)
    out = System.cmd("git", ["--git-dir=#{bare}", "--work-tree=#{work_dir}", "-c", "core.bare=false",
                       "checkout", "-f", branch], stderr_to_stdout: true)
    maybe_colocate(bare, work_dir)
    out
  end

  @doc """
  Configure a mirror remote (e.g. the org's GitHub) for a bare repo. After each push, the post-receive
  mirrors all refs to it. Generic — `url` is any git remote (GitHub is just a URL with a token in it);
  pass `nil`/"" to clear. The runtime carries the mechanism; the GitHub URL+token is the deployer's config.
  """
  def set_mirror(bare, url) when is_binary(url) and url != "" do
    System.cmd("git", ["--git-dir=#{bare}", "config", "workbooks.mirror", url], stderr_to_stdout: true)
    :ok
  end

  def set_mirror(bare, _), do: (System.cmd("git", ["--git-dir=#{bare}", "config", "--unset", "workbooks.mirror"], stderr_to_stdout: true); :ok)

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
    # Mirror to the configured remote (e.g. the org's GitHub), if one is set. Best-effort.
    mirror=$(git --git-dir="#{bare}" config --get workbooks.mirror 2>/dev/null)
    if [ -n "$mirror" ]; then
      git --git-dir="#{bare}" push --mirror "$mirror" && echo "workbooks: mirrored to $mirror" || echo "workbooks: mirror push failed"
    fi
    """
  end
end
