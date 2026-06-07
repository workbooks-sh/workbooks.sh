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

  # ── checkout / check-in (borrow ⇄ return = unpack ⇄ pack) ────────────────────

  @doc """
  Check a member OUT of the Library into `workdir` — the unpacked working form
  (the same workdir/scratch the workflow runs). A `.wbundle` member is unpacked
  via `Bundle.restore`; a plain file is copied. DID members resolve on demand
  (not wired — extension point). Returns %{member, workdir, scope} or %{error}.
  """
  def checkout(tenant, member_id, workdir) do
    case find(tenant, member_id) do
      nil -> %{error: "no such member: #{member_id}"}
      %{ref: {:path, p}} = m ->
        File.mkdir_p!(workdir)
        place(Path.join(Git.repo_path(tenant), p), workdir)
        %{member: m, workdir: workdir, scope: access(tenant, tenant, m.scope)}

      %{ref: {:did, _}} = m -> %{error: "DID resolution not wired", member: m}
      m -> %{error: "unresolved member", member: m}
    end
  end

  @doc """
  Check a member back IN — pack the workdir's `workbook.html`, SIGN it with the
  tenant did:key (`Workbooks.Manifest`, the pack-and-sign step), and write it
  back to the member's repo path. Returns %{member, bytes} or %{error}.
  """
  def checkin(tenant, member_id, workdir) do
    with %{ref: {:path, p}} = m <- find(tenant, member_id),
         {:ok, html} <- File.read(Path.join(workdir, "workbook.html")) do
      signed = Workbooks.Manifest.sign(html, tenant, [%{"type" => "c2pa.action.updated", "actor" => Git.did(tenant)}])
      dest = Path.join(Git.repo_path(tenant), p)
      File.write!(dest, signed)
      %{member: m, bytes: byte_size(signed)}
    else
      nil -> %{error: "no such member: #{member_id}"}
      {:error, _} -> %{error: "no workbook.html in #{workdir}"}
      m -> %{error: "member not a path ref", member: m}
    end
  end

  defp find(tenant, member_id), do: Enum.find(members(tenant), &(&1.id == member_id))

  # Unpack a member into the working dir: a .wbundle → its html + vfs; else copy.
  defp place(src, workdir) do
    if String.ends_with?(src, ".wbundle") and File.exists?(src) do
      {_m, html, vfs} = Workbooks.Bundle.restore(File.read!(src))
      File.write!(Path.join(workdir, "workbook.html"), html)
      File.write!(Path.join(workdir, "vfs.sqlite"), vfs)
    else
      File.cp(src, Path.join(workdir, "workbook.html"))
    end
  end

  defp normalize(s) when s in ["read", "write"], do: s
  defp normalize(_), do: "read"
end
