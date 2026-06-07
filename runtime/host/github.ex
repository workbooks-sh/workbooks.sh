defmodule Workbooks.GitHub do
  @moduledoc """
  The GitHub source rail (Phase 2a/2b) — mirror a tenant's git repo to GitHub.
  The UNPACKED monorepo (source, readable + diffable) lives here; the auto-written
  `.gitignore` (`Workbooks.Private`) keeps session/personal data out by default.

  Leanest path, per SHARING-RAILS-PORT.org: lean on the `gh` CLI on PATH (the same
  toolkit pattern as jj/rad/c2patool) — no GitHub App, no installation-token dance.
  A full App only earns its complexity at per-tenant-installation scale. Host side
  is a thin shell; `gh` owns auth + the API.
  """
  alias Workbooks.Git

  @doc "Is `gh` present AND authenticated? Everything no-ops cleanly otherwise."
  def available? do
    has?("gh") and match?({_, 0}, gh(["auth", "status"], "."))
  end

  @doc """
  Create-or-push the tenant's repo to GitHub (idempotent). First push creates the
  repo from the local source; later pushes just push. Returns {:ok, url} | {:skip,
  reason} | {:error, out}. opts: :repo (name, default `wb-<tenant>`), :visibility
  ("private" default), :remote (default "origin").
  """
  def push(tenant, opts \\ []) do
    if available?() do
      dir = Git.ensure_repo(tenant)
      ensure_commit(dir, tenant)
      name = opts[:repo] || "wb-#{tenant}"
      remote = opts[:remote] || "origin"

      if has_remote?(dir, remote) do
        case git(dir, ["push", remote, "HEAD"]) do
          {_, 0} -> {:ok, repo_url(dir, remote)}
          {out, _} -> {:error, out}
        end
      else
        vis = "--" <> (opts[:visibility] || "private")

        case gh(["repo", "create", name, "--source", ".", vis, "--push", "--remote", remote], dir) do
          {_, 0} -> {:ok, repo_url(dir, remote)}
          {out, _} -> {:error, out}
        end
      end
    else
      {:skip, "gh not installed or not authenticated"}
    end
  end

  @doc "Delete a GitHub repo (cleanup for tests / retired mirrors). owner/name or name."
  def delete(repo), do: gh(["repo", "delete", repo, "--yes"], ".")

  # ── internals ─────────────────────────────────────────────────────────────────
  defp ensure_commit(dir, tenant) do
    case git(dir, ["rev-parse", "HEAD"]) do
      {_, 0} -> :ok
      _ -> Git.save(Git.identity(tenant), "README", "* #{tenant}\n  Workbooks tenant repo.\n")
    end
  end

  defp has_remote?(dir, remote), do: match?({_, 0}, git(dir, ["remote", "get-url", remote]))

  defp repo_url(dir, remote) do
    case git(dir, ["remote", "get-url", remote]) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  end

  defp git(dir, args), do: System.cmd("git", ["-c", "core.hooksPath=/dev/null" | args], cd: dir, stderr_to_stdout: true)
  defp gh(args, dir), do: System.cmd("gh", args, cd: dir, stderr_to_stdout: true)
  defp has?(bin), do: match?({_, 0}, System.cmd("sh", ["-c", "command -v #{bin}"], stderr_to_stdout: true))
end
