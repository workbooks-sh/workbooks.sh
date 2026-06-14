defmodule Workbooks.SharedFolder do
  @moduledoc """
  Phase 3 — **Shared folders** ("share a folder · add it to your workspace"). The
  user-vocabulary policy layer over per-tenant git repos: it lets one tenant share a
  FOLDER with another, and lets the recipient ADD that folder to their workspace as a
  Draft. Zero plumbing vocabulary leaves this module — no subtree, filter, josh, git.

  (The org-mode `workspace.org` manifest parser is a different concern —
  `Workbooks.Workspace`. This module is the runtime sharing capability.)

  ## The one place data crosses a tenant boundary — and how it's confined
  Everything else in the system is single-tenant by construction; this is the sole
  capability that moves bytes between two tenants, so it is gated on every axis:

    * **Share** is owner-only: you can share only a folder that exists under your own
      repo's `shared/` tree (`Git.shareable_folders/1` is the allow-list). You cannot
      "share" another tenant's folder, a path outside `shared/`, or a made-up name.
    * **A grant names exactly one folder.** It is the SOLE key that unlocks a cross-
      tenant copy, and it unlocks only that one folder for that one recipient.
    * **Add** is recipient-only: you can add a folder to YOUR workspace only if a
      grant names you as its recipient. A non-recipient (or a stranger guessing a
      grant id) gets `:not_found` — fail-closed, leaking nothing.
    * The copy itself (`Git.copy_subtree/4`) is structurally confined to `shared/
      <folder>` — it can never reach a sibling folder, a repo-root file (the signed
      ledger, the `.workbooks/` signing keys), or `..`.

  ## No native subtree daemon
  josh (the Rust git-proxy) is prior art we modelled the `:/shared/<folder>` subtree
  shape on — we do NOT run it. There is no new Rust NIF and no `josh-proxy` OS
  process; the projection is pure Elixir over the existing git store
  (`Git.copy_subtree/4`), the host trusted-broker tier `Workbooks.Git` already uses.
  The shipped behaviour is pull-on-demand → Draft, and that is the whole capability —
  not a placeholder for a later native sync.
  """

  alias Workbooks.{Git, ControlPlane}

  @modes ~w(read draft)a

  @doc """
  Share `folder` (one of your own `shared/` folders) with `recipient` in `mode`
  (`:read` | `:draft`). Owner-gated.

  `{:ok, grant}`; `{:error, :bad_request}` (bad mode / sharing with yourself / nil
  tenant); `{:error, :no_such_folder}` (not a folder you own under `shared/`).
  """
  def share(caller, folder, recipient, mode \\ :read) do
    cond do
      not tenant?(caller) or not tenant?(recipient) -> {:error, :bad_request}
      caller == recipient -> {:error, :bad_request}
      mode not in @modes -> {:error, :bad_request}
      folder not in Git.shareable_folders(caller) -> {:error, :no_such_folder}
      true -> {:ok, ControlPlane.put_share(caller, folder, recipient, mode)}
    end
  end

  @doc "Folders `tenant` shares OUT (each `%{id, owner, folder, recipient, mode}`)."
  def shared_by(tenant), do: if(tenant?(tenant), do: ControlPlane.shares_by(tenant), else: [])

  @doc "Folders shared WITH `tenant` — what it can add to its workspace."
  def shared_with(tenant), do: if(tenant?(tenant), do: ControlPlane.shares_for(tenant), else: [])

  @doc "Folders `tenant` could share (its own `shared/` subdirectories)."
  def shareable(tenant), do: if(tenant?(tenant), do: Git.shareable_folders(tenant), else: [])

  @doc """
  Add a shared folder to YOUR workspace as a Draft. `caller` must be the named
  recipient of grant `share_id` — anything else is `:not_found` (fail-closed, no
  distinction between a wrong recipient and a non-existent grant).

  `{:ok, %{folder, files}}`; `{:error, :not_found}`; `{:error, reason}` on a genuine
  copy failure.
  """
  def add_to_workspace(caller, share_id) do
    with true <- tenant?(caller),
         %{owner: owner, folder: folder, recipient: ^caller} <- ControlPlane.get_share(share_id) do
      case Git.copy_subtree(owner, folder, caller, "#{owner}__#{folder}") do
        {:ok, %{files: files}} -> {:ok, %{folder: folder, files: files}}
        {:error, reason} -> {:error, reason}
      end
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Stop sharing — revoke grant `share_id`. `caller` must be the grant's OWNER (else
  `:not_found`). Blocks future adds; a copy the recipient already vendored is their
  own Draft and is not clawed back.
  """
  def revoke(caller, share_id) do
    with true <- tenant?(caller),
         %{owner: ^caller} <- ControlPlane.get_share(share_id) do
      ControlPlane.delete_share(share_id)
      :ok
    else
      _ -> {:error, :not_found}
    end
  end

  # A well-formed tenant principal: bounded, no control chars / separators / path
  # bits. There is no enumerable "tenant registry" to check membership against
  # (principals are WorkOS org ids, our own ids, or ephemeral `eph-…` — all match
  # this charset), so this is a FORMAT floor only. A grant's recipient EXISTENCE is
  # enforced where it matters — at redemption: `add_to_workspace` pins
  # `recipient == authenticated caller`, so a grant to a non-existent/typo'd tenant
  # is simply inert (nobody can ever authenticate as it to redeem). That's the real
  # security property; this check just stops malformed/garbage recipients.
  defp tenant?(t), do: is_binary(t) and t =~ ~r/\A[A-Za-z0-9_-]{1,128}\z/
end
