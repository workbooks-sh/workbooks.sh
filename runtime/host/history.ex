defmodule Workbooks.History do
  @moduledoc """
  Phase 1 — History + Restore (the "nothing is lost, restore anything" promise).

  A thin, TENANT-GATED reader/writer over `Workbooks.Git` that turns the per-tenant
  git ledger into the user-facing **History** of a **scope** (a workbook id), with an
  APPEND-ONLY **Restore**. Zero git vocabulary leaves this module — the API speaks
  Changes (`%{id, when, author_type, author_name, title}`), before/after, and restore.

  ## Confinement (wb-g1yo.10)
  `scope` is an OPAQUE WORKBOOK ID — never a filesystem path. Every function first
  resolves the scope's owning tenant via `ControlPlane.workbook_tenant/1` and gates
  it with the CANONICAL ownership rule `ControlPlane.workbook_visible?/2` (the same
  gate the rest of wb-g1yo uses — `/instances`, `/api/sessions`), so there is one
  ownership rule, not a parallel hand-rolled one. This fails CLOSED:

    * unknown scope (`:not_found`)      -> `{:error, :not_found}`
    * cross-tenant scope (owner != me)  -> `{:error, :not_found}`
    * nil / empty caller tenant         -> `{:error, :not_found}`

  So a caller can only ever read or restore history for a workbook their own tenant
  owns — an arbitrary caller-supplied id can't reach another tenant's repo, and a
  path-shaped scope is a non-existent workbook (`:not_found`) regardless. The git
  file backing a scope is always `<scope>.org` inside the OWNER's repo; the scope is
  never joined onto a path here, the web layer additionally rejects path characters.

  ## Human vs agent attribution (heuristic)
  Git records only an author name + email per commit; there is no first-class
  "this was an agent" flag yet. We classify a Change as `:agent` when the commit
  author name OR email matches an agent marker — `agent`, `ledger`, `keeper`, or
  the `waldo` keeper identity (case-insensitive) — and `:human` otherwise. Agent
  writes flow through the host git tool (`Git.commit_and_push`) and the ledger
  (`Git.save` with author `agent-ledger`); human deploys commit under the tenant's
  own name. This is a best-effort signal, not ground truth — a richer per-commit
  author-type tag is a later phase (named workspace members).
  """

  alias Workbooks.{Git, ControlPlane}

  @agent_markers ~w(agent ledger keeper waldo)

  @doc """
  Reverse-chron timeline of Changes for an owned `scope`.

  Returns `[%{id, when, author_type, author_name, title}]` (newest first) on
  success, or `{:error, :not_found}` if the caller's `tenant` doesn't own `scope`.
  """
  def timeline(scope, tenant) do
    with {:ok, owner} <- authorize(scope, tenant) do
      entries =
        owner
        |> Git.log_entries(scope)
        |> Enum.map(fn %{sha: sha, ts: ts, author: author, msg: msg} ->
          %{
            id: sha,
            when: ts,
            author_type: author_type(author),
            author_name: author,
            title: msg
          }
        end)

      {:ok, entries}
    end
  end

  @doc """
  Before/after for one Change `id` within an owned `scope`.

  `{:ok, %{before: binary, after: binary}}` on success; `{:error, :not_found}` on a
  cross-tenant/unknown scope; `{:error, :bad_id}` if `id` isn't a valid change.
  """
  def diff(scope, id, tenant) do
    with {:ok, owner} <- authorize(scope, tenant),
         true <- valid_id?(id) do
      {:ok, Git.scope_diff(owner, scope, id)}
    else
      {:error, _} = e -> e
      false -> {:error, :bad_id}
    end
  end

  @doc """
  APPEND-ONLY restore: re-apply the version of `scope` at change `to_id` as a NEW
  Change. Reads the file content at `to_id`, writes it as the working copy, and
  commits — NEVER `reset --hard`, never history rewrite. The prior timeline stays
  fully intact; restore only ever ADDS an entry.

  `{:ok, %{id, when, author_type, author_name, title}}` (the new Change) on success;
  `{:ok, :unchanged}` if the working copy already equals `to_id`'s content (no new
  Change, not an error); `{:error, :not_found}` cross-tenant/unknown scope;
  `{:error, :bad_id}` if `to_id` isn't a real change in THIS scope's own timeline;
  `{:error, reason}` if the commit genuinely failed.
  """
  def restore(scope, to_id, tenant) do
    with {:ok, owner} <- authorize(scope, tenant),
         true <- valid_id?(to_id),
         true <- in_timeline?(owner, scope, to_id) do
      case Git.restore(owner, scope, to_id) do
        {:ok, :unchanged} ->
          # already at that exact content — no new Change, but not an error
          {:ok, :unchanged}

        {:ok, sha} ->
          [change] =
            owner
            |> Git.log_entries(scope)
            |> Enum.filter(&(&1.sha == sha))
            |> Enum.map(fn %{sha: s, ts: ts, author: author, msg: msg} ->
              %{id: s, when: ts, author_type: author_type(author), author_name: author, title: msg}
            end)

          {:ok, change}

        # a genuine commit failure — surfaced, never reported as success
        {:error, _} = e ->
          e
      end
    else
      {:error, _} = e -> e
      false -> {:error, :bad_id}
    end
  end

  # The restore target MUST be a change that appears in THIS scope's own timeline
  # (the `<scope>.org` file's git history), not merely any sha in the tenant repo —
  # otherwise a caller could restore a workbook to an unrelated revision that touched
  # a different file. `to_id` is a short-sha; match against either the short sha or a
  # prefix of a full sha in the scope's log.
  defp in_timeline?(owner, scope, to_id) do
    owner
    |> Git.log_entries(scope)
    |> Enum.any?(fn %{sha: s} -> s == to_id or String.starts_with?(s, to_id) or String.starts_with?(to_id, s) end)
  end

  # --- gating -----------------------------------------------------------------

  # Resolve + confine the scope to the caller's tenant. Fails CLOSED: a nil/empty
  # caller, an unknown scope, or a cross-tenant scope all map to {:error,:not_found}
  # so nothing about another tenant's repo (existence included) is observable.
  defp authorize(scope, tenant) do
    cond do
      not is_binary(tenant) or tenant == "" ->
        {:error, :not_found}

      not is_binary(scope) or scope == "" ->
        {:error, :not_found}

      true ->
        # Resolve the owner so we know which repo backs this scope, then gate with
        # the ONE canonical ownership rule (`ControlPlane.workbook_visible?/2`) — no
        # parallel hand-rolled check. An unknown scope has no backing repo, so it is
        # fail-closed to :not_found here even though `workbook_visible?` grandfathers
        # unknown ids; we only ever consult it for the cross-tenant DECISION.
        case ControlPlane.workbook_tenant(scope) do
          :not_found ->
            {:error, :not_found}

          owner ->
            if ControlPlane.workbook_visible?(scope, tenant),
              do: {:ok, owner || tenant},
              else: {:error, :not_found}
        end
    end
  end

  # A valid change id is a git short-sha (hex). Reject anything else up front so a
  # caller can't smuggle a revision expression / flag into the git invocation.
  defp valid_id?(id), do: is_binary(id) and id =~ ~r/\A[0-9a-f]{4,40}\z/

  defp author_type(author) do
    a = String.downcase(author || "")
    if Enum.any?(@agent_markers, &String.contains?(a, &1)), do: :agent, else: :human
  end
end
