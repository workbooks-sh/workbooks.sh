defmodule Workbooks.Draft do
  @moduledoc """
  Phase 5 — **Drafts** ("try a change safely; Keep it or Discard it"). A Draft is an
  isolated copy of a tenant's workspace where edits accumulate WITHOUT touching the
  live version, with a preview, that you either **Keep** (fold into the live version)
  or **Discard** (throw away, the live version never changed). Zero git vocabulary
  leaves this module — only Draft / preview / Keep / Discard.

  ## Isolation model (invisible plumbing)
  A Draft is a named branch `draft/<name>` checked out in its OWN working tree under
  the repo's gitignored `.drafts/<name>/` — a `git worktree`. So the LIVE tree (what
  the nexus serves) stays on its base branch and keeps serving while the Draft is
  edited and previewed in parallel. `Keep` merges the draft branch into base with a
  real merge commit (append-only — never a force/reset), then tears the worktree
  down. `Discard` removes the worktree and deletes the branch; base is untouched.

  ## Confinement
  Per-tenant by construction (`Git.repo_path/1`), like every other store op. `name`
  is a single allow-listed segment (`[A-Za-z0-9_-]+`), so the branch ref and the
  `.drafts/<name>` worktree path can never escape the repo or smuggle a git flag.
  Tenant ownership + the RBAC `:edit` capability are enforced at the web layer; this
  module trusts the resolved tenant exactly as `SharedFolder`/`History` do.
  """

  alias Workbooks.Git

  @doc """
  Open a new Draft `name` off the live version. Returns `{:ok, %{name, preview_path}}`,
  `{:error, :bad_name}`, `{:error, :exists}`, or `{:error, reason}`.
  """
  def create(tenant, name) do
    with :ok <- valid_name(name) do
      dir = Git.ensure_repo(tenant)
      wt = worktree_path(dir, name)

      cond do
        branch_exists?(dir, branch(name)) or File.dir?(wt) ->
          {:error, :exists}

        true ->
          File.mkdir_p!(Path.join(dir, ".drafts"))

          case git(dir, ["worktree", "add", "-b", branch(name), wt, "HEAD"]) do
            {_, 0} -> {:ok, %{name: name, preview_path: Path.relative_to(wt, dir)}}
            {out, _} -> {:error, String.slice(String.trim(out), 0, 160)}
          end
      end
    end
  end

  @doc "Open Drafts for a tenant → `[%{name, files_changed, preview_path}]` (newest branch first)."
  def list(tenant) do
    dir = Git.ensure_repo(tenant)
    base = base_branch(dir)

    case git(dir, ["for-each-ref", "--format=%(refname:short)", "refs/heads/draft/"]) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.map(fn ref -> String.replace_prefix(ref, "draft/", "") end)
        |> Enum.filter(&(valid_name(&1) == :ok))
        |> Enum.map(fn name ->
          %{name: name, files_changed: changed_count(dir, base, branch(name)), preview_path: ".drafts/#{name}"}
        end)

      _ ->
        []
    end
  end

  @doc """
  What a Draft changes vs the live version → `{:ok, [%{path, status}]}` (status =
  `\"added\"|\"modified\"|\"removed\"`), or `{:error, :not_found}`.
  """
  def diff(tenant, name) do
    dir = Git.ensure_repo(tenant)

    with :ok <- valid_name(name),
         true <- branch_exists?(dir, branch(name)) do
      {out, _} = git(dir, ["diff", "--name-status", "#{base_branch(dir)}..#{branch(name)}"])

      changes =
        out
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case String.split(line, "\t", parts: 2) do
            [code, path] -> [%{path: path, status: status(code)}]
            _ -> []
          end
        end)

      {:ok, changes}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  **Keep** a Draft — fold it into the live version with an append-only merge commit,
  then remove the Draft. `{:ok, %{merged: name}}`, `{:error, :not_found}`,
  `{:error, :conflict}` (live changed the same lines — left for a person), or
  `{:error, reason}`.
  """
  def keep(tenant, name) do
    dir = Git.ensure_repo(tenant)

    with :ok <- valid_name(name),
         true <- branch_exists?(dir, branch(name)) do
      # merge in the LIVE tree (base is checked out there). No fast-forward so a Draft
      # is always a visible, revertible event in History; never a reset/force.
      case git(dir, ["-c", "core.hooksPath=/dev/null", "merge", "--no-ff", "--no-edit", branch(name)],
             env: commit_env(tenant)
           ) do
        {_, 0} ->
          _ = teardown(dir, name)
          {:ok, %{merged: name}}

        {_, _} ->
          # abort the half-merge so the live tree stays clean; the Draft survives
          git(dir, ["merge", "--abort"])
          {:error, :conflict}
      end
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "**Discard** a Draft — remove it entirely; the live version never changed. `:ok` or `{:error, :not_found}`."
  def discard(tenant, name) do
    dir = Git.ensure_repo(tenant)

    with :ok <- valid_name(name),
         true <- branch_exists?(dir, branch(name)) do
      teardown(dir, name)
      :ok
    else
      _ -> {:error, :not_found}
    end
  end

  # --- plumbing ---------------------------------------------------------------

  defp teardown(dir, name) do
    git(dir, ["worktree", "remove", "--force", worktree_path(dir, name)])
    git(dir, ["branch", "-D", branch(name)])
    :ok
  end

  defp branch(name), do: "draft/#{name}"
  defp worktree_path(dir, name), do: Path.join([dir, ".drafts", name])

  defp branch_exists?(dir, ref) do
    case git(dir, ["rev-parse", "--verify", "--quiet", "refs/heads/#{ref}"]) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp base_branch(dir) do
    case git(dir, ["symbolic-ref", "--short", "HEAD"]) do
      {out, 0} -> String.trim(out)
      _ -> "main"
    end
  end

  defp changed_count(dir, base, ref) do
    case git(dir, ["diff", "--name-only", "#{base}..#{ref}"]) do
      {out, 0} -> out |> String.split("\n", trim: true) |> length()
      _ -> 0
    end
  end

  defp status("A"), do: "added"
  defp status("D"), do: "removed"
  defp status(_), do: "modified"

  # A Draft name is a single safe segment — no separators / `..` / leading dash.
  defp valid_name(n) when is_binary(n), do: if(n =~ ~r/\A[A-Za-z0-9_-]+\z/, do: :ok, else: {:error, :bad_name})
  defp valid_name(_), do: {:error, :bad_name}

  # Commit identity = the tenant (mirrors Git.commit_env), so a Keep is attributed.
  defp commit_env(tenant) do
    %{author: author, email: email} = Git.identity(tenant)
    [{"GIT_AUTHOR_NAME", author}, {"GIT_AUTHOR_EMAIL", email}, {"GIT_COMMITTER_NAME", author}, {"GIT_COMMITTER_EMAIL", email}]
  end

  defp git(dir, args, opts \\ []),
    do: System.cmd("git", ["-c", "safe.directory=*", "-c", "safe.directory=#{dir}"] ++ args, [cd: dir, stderr_to_stdout: true] ++ opts)
end
