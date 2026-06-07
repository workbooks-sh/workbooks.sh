defmodule Workbooks.Library do
  @moduledoc """
  The Library (Phase 3, the top layer) — what ONE identity (a user or org) can
  reach. Not a folder: an ACCESS GRAPH over the identity's workspaces + their
  members, with a scope on each. Tied to the tenant (Guardian's `organizationId`
  / `sub`), never shared — sharing happens to the CONTENTS, on egress.

  The Library is an INDEX + ACCESS layer that composes what already exists — it
  is not new machinery (golden rules):
    * workspaces       ← `workspace.org` manifests in the tenant's git repo
                         (`Workbooks.Git` / `Workbooks.Workspace`)
    * effective scope  ← the member's declared scope ∩ the requester's grant
                         (Guardian tenant ownership today; cross-org grants are
                         the documented extension point)
    * backup/sync      ← projecting workspaces to git is the MONOREPO, separate
    * provenance       ← every member is did:key/C2PA-linked (`Workbooks.Manifest`)

  See docs/IDENTITY-GIT-MONOREPO.org "The Library".
  """
  alias Workbooks.{Git, Workspace}

  @doc "Every workspace in the tenant's Library — its `workspace.org` manifests, parsed."
  def workspaces(tenant) do
    Git.repo_path(tenant)
    |> Path.join("**/workspace.org")
    |> Path.wildcard()
    |> Enum.map(fn path ->
      ws = Workspace.parse(File.read!(path))
      Map.put(ws, :path, path)
    end)
  end

  @doc """
  The Library's contents flattened — every member across every workspace, each
  tagged with its owning workspace slug. This IS the access graph's node set.
  """
  def members(tenant) do
    for ws <- workspaces(tenant), m <- ws.members, do: Map.put(m, :workspace, ws.slug)
  end

  @doc """
  Resolve the effective scope a `requester` identity has on a member whose
  manifest DECLARES `declared` ("read"/"write"). The owner gets the declared
  scope (capped — can't exceed it); a different identity gets "none" until a
  cross-org grant is wired (the extension point). Returns "read"|"write"|"none".
  """
  def access(owner, requester, declared) do
    cond do
      to_string(owner) == to_string(requester) -> normalize(declared)
      true -> "none"
    end
  end

  @doc "The Library owner's did:key — the identity every member is signed/scoped under."
  def did(tenant), do: Git.did(tenant)

  defp normalize(s) when s in ["read", "write"], do: s
  defp normalize(_), do: "read"
end
