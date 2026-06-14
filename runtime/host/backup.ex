defmodule Workbooks.Backup do
  @moduledoc """
  Phase 6 — **Backup** (the optional developer-friendly GitHub/GitLab lens). A tenant
  can back its whole workspace up to a git host and keep it mirrored — a legible,
  one-way export where the workspace's structure maps cleanly: Drafts → branches,
  shared folders → directories, Changes → commits (it IS the same git repo). Spoken
  to users as **Backup** / **Connected** / **Disconnect**; the host (GitHub/GitLab/
  Gitea) is named factually, but no git verbs leak.

  Thin policy over the existing rail (`Git.forge_push/2`, `Git.mirror/3`,
  `Git.backup_status/1`): pure orchestration, no new transport. Per-tenant by
  construction; configuring/triggering a backup is an RBAC `:manage` capability,
  enforced at the web layer.
  """

  alias Workbooks.Git

  @doc """
  Connect (and push) a tenant's backup. Either an explicit `:url` (any git host) or
  `:forge` (\"github\"|\"gitlab\"|\"gitea\") to auto-provision via its CLI. Returns
  `{:ok, %{url}}`, `{:skip, reason}` (no forge CLI / nothing to push), or `{:error, _}`.
  """
  def connect(tenant, opts \\ []) do
    cond do
      is_binary(opts[:url]) and opts[:url] != "" ->
        case Git.mirror(tenant, opts[:url]) do
          {:ok, url} -> {:ok, %{url: url}}
          other -> other
        end

      true ->
        case Git.forge_push(tenant, opts) do
          {:ok, url} -> {:ok, %{url: url}}
          {:skip, r} -> {:skip, r}
          other -> other
        end
    end
  end

  @doc "Push the latest workspace state to an already-connected backup. `{:ok, %{url}}` | `{:skip,_}` | `{:error,_}`."
  def push(tenant) do
    case Git.forge_push(tenant) do
      {:ok, url} -> {:ok, %{url: url}}
      other -> other
    end
  end

  @doc "Is a backup connected, and where → `%{connected, host, url}` (host inferred from the URL)."
  def status(tenant) do
    %{connected: connected, url: url} = Git.backup_status(tenant)
    %{connected: connected, url: url, host: host_of(url)}
  end

  @doc "Disconnect the backup (stops mirroring; the remote copy is left in place). `:ok`."
  def disconnect(tenant), do: Git.backup_disconnect(tenant)

  # A friendly host label from a remote URL — purely cosmetic for the dashboard.
  defp host_of(nil), do: nil
  defp host_of(url) do
    cond do
      String.contains?(url, "github.com") -> "GitHub"
      String.contains?(url, "gitlab.com") -> "GitLab"
      String.contains?(url, "gitea") -> "Gitea"
      true -> "Git host"
    end
  end
end
