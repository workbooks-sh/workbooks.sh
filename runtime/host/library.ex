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

      %{ref: {:did, did}} = m ->
        case Workbooks.Did.resolve(did) do
          {:ok, bytes} ->
            File.mkdir_p!(workdir)
            File.write!(Path.join(workdir, "workbook.html"), bytes)
            %{member: m, workdir: workdir, scope: access(tenant, tenant, m.scope), resolved: did}

          {:error, e} -> %{error: "resolve #{did}: #{e}", member: m}
        end

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

  @doc """
  Cross-workbook OQL query-through — run one SQL across EVERY member that carries
  a queryable SQLite VFS (a `.wbundle`), returning rows tagged by member. The
  Library reads as one queryable surface without merging the workbooks. Members
  with no VFS (html-only, unresolved DID) are reported in `skipped`, never
  silently dropped. Reuses `VFS.open`/`VFS.query_json` — no new query engine.
  """
  def query(tenant, sql) do
    {hits, skipped} =
      members(tenant)
      |> Enum.reduce({[], []}, fn m, {hits, skipped} ->
        case member_vfs_bytes(tenant, m) do
          {:ok, bytes} ->
            rows = query_bytes(bytes, sql)
            {[%{member: m.id, workspace: m.workspace, rows: rows} | hits], skipped}

          :none -> {hits, [m.id | skipped]}
        end
      end)

    %{rows: Enum.reverse(hits), skipped: Enum.reverse(skipped)}
  end

  defp member_vfs_bytes(tenant, %{ref: {:path, p}}) do
    src = Path.join(Git.repo_path(tenant), p)
    if String.ends_with?(src, ".wbundle") and File.exists?(src) do
      {_m, _html, vfs} = Workbooks.Bundle.restore(File.read!(src))
      {:ok, vfs}
    else
      :none
    end
  end

  defp member_vfs_bytes(_tenant, _m), do: :none

  defp query_bytes(bytes, sql) do
    tmp = Path.join(System.tmp_dir!(), "lib-q-#{:erlang.phash2({bytes, sql})}.sqlite")
    File.write!(tmp, bytes)
    {:ok, conn} = Workbooks.VFS.open(tmp)
    json = Workbooks.VFS.query_json(conn, sql)
    Exqlite.Sqlite3.close(conn)
    File.rm(tmp)
    Jason.decode!(json)
  rescue
    e -> %{"error" => Exception.message(e)}
  end

  @doc """
  PACK a workspace into one parent workbook (the fractal "compile to another
  workbook" — containers hold containers). Bundles the `workspace.org` manifest +
  every path member's bytes into a single `.wbundle`, so a project of feature
  workbooks becomes one shippable parent. Privacy by default: personal/session
  files are stripped (`Workbooks.Private`); `include_private: true` to keep them.
  Returns {:ok, blob} or {:error, reason}. (DID members are referenced, not
  vendored — resolved on unpack; extension point.)
  """
  def pack(tenant, workspace_slug, opts \\ []) do
    # Two egress purposes (the storage-vs-share distinction):
    #   :share   (default) — strip personal/session data; what a recipient gets.
    #   :archive           — keep everything; YOUR complete snapshot, so a
    #                        re-download of your own backup still has your session.
    # `include_private: true` is the low-level equivalent (:archive sets it).
    include_private = opts[:include_private] || opts[:purpose] == :archive

    case Enum.find(workspaces(tenant), &(&1.slug == workspace_slug)) do
      nil -> {:error, "no such workspace: #{workspace_slug}"}
      ws ->
        repo = Git.repo_path(tenant)
        # Partial vs full: opts[:only] packs just those member ids; default = all.
        members = case opts[:only] do
          nil -> ws.members
          ids -> Enum.filter(ws.members, &(&1.id in List.wrap(ids)))
        end

        parts =
          members
          |> Enum.flat_map(fn
            %{ref: {:path, p}} -> vendor(repo, p)
            # A DID member is RESOLVED (fetched) + vendored under its id, so the
            # parent workbook carries the referenced workbook's bytes.
            %{ref: {:did, did}, id: id} ->
              case Workbooks.Did.resolve(did), do: ({:ok, b} -> [{"#{id}.html", b}]; _ -> [])

            _ -> []
          end)
          |> Map.new()
          |> Map.put("workspace.org", File.read!(ws.path))

        # Privacy = built-in safe defaults (Workbooks.Private) PLUS the repo's own
        # `.gitignore`, honored via git's OWN matcher (`git check-ignore`). So the
        # agent's NATIVE git instinct — the .gitignore it already writes — IS the
        # share boundary; there's no bespoke API to learn, and the defaults hold
        # even if it writes nothing. Safe by default, native by design.
        parts = if include_private, do: parts, else: parts |> Workbooks.Private.strip_parts() |> drop_gitignored(repo)
        parts = if opts[:build], do: build_projection(parts, include_private), else: parts
        {:ok, Workbooks.Bundle.pack(parts)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  UNPACK a parent workbook back to a flat tree under `dest` — the working form
  (the monorepo projection). Mirror of `pack/3`; reuses `Bundle.unpack`.
  Returns the list of files written.
  """
  def unpack(blob, dest) when is_binary(blob) do
    File.mkdir_p!(dest)

    for {name, content} <- Workbooks.Bundle.unpack(blob) do
      path = Path.join(dest, name)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
      name
    end
  end

  @doc """
  Compile a workspace's components and return the build report (what became WASM,
  what couldn't). The report behind `wb build` / `pack --build`. Builds a throwaway
  copy of the parts so the tenant repo stays clean.
  """
  def build(tenant, workspace_slug) do
    case pack(tenant, workspace_slug, purpose: :archive) do
      {:ok, blob} ->
        tmp = Path.join(System.tmp_dir!(), "wb-build-#{:erlang.phash2({tenant, workspace_slug})}")
        File.rm_rf!(tmp)
        unpack(blob, tmp)
        report = Workbooks.Build.build(tmp)
        File.rm_rf(tmp)
        %{built: Enum.map(report.built, &Map.drop(&1, [:bytes])), unbuilt: report.unbuilt}

      {:error, e} -> %{error: e}
    end
  end

  # The RUNNABLE projection: compile components, then ship the .wasm OUTPUTS while
  # dropping the source build INPUTS (a workbook runs WebAssembly, not source).
  # Built in a temp tree so nothing leaks into the tenant repo. Archive keeps both.
  defp build_projection(parts, include_private) do
    tmp = Path.join(System.tmp_dir!(), "wb-pack-build-#{:erlang.phash2(parts)}")
    File.rm_rf!(tmp)

    Enum.each(parts, fn {name, content} ->
      p = Path.join(tmp, name)
      File.mkdir_p!(Path.dirname(p))
      File.write!(p, content)
    end)

    report = Workbooks.Build.build(tmp)
    wasm = Map.new(report.built, fn b -> {b.name <> ".wasm", b.bytes} end)
    File.rm_rf(tmp)

    parts = if include_private, do: parts, else: Map.reject(parts, fn {n, _} -> Workbooks.Build.build_input?(n) end)
    Map.merge(parts, wasm)
  end

  # Vendor a member's bytes into the parent. A FILE member → that one file; a
  # DIRECTORY member (a feature folder of mixed-language source — Svelte, Rust,
  # SQL…) → its whole subtree, each file keyed by its repo-relative path so the
  # tree round-trips exactly on unpack. Language-agnostic: it's just bytes+paths.
  defp vendor(repo, p) do
    full = Path.join(repo, p)

    cond do
      File.dir?(full) ->
        full
        |> Path.join("**/*")
        |> Path.wildcard()
        |> Enum.filter(&File.regular?/1)
        |> Enum.map(fn f -> {Path.relative_to(f, repo), File.read!(f)} end)

      File.regular?(full) -> [{p, File.read!(full)}]
      true -> []
    end
  end

  # Drop any part the tenant repo's .gitignore covers — using git's own matcher,
  # not a reimplementation (DRY + exact git semantics). The agent marks "don't
  # share" the same way it marks "don't track": a .gitignore line it already knows.
  defp drop_gitignored(parts, repo) do
    names = Map.keys(parts)

    ignored =
      case System.cmd("git", ["check-ignore" | names], cd: repo, stderr_to_stdout: true) do
        {out, _} -> out |> String.split("\n", trim: true) |> MapSet.new()
        _ -> MapSet.new()
      end

    Map.reject(parts, fn {name, _} -> MapSet.member?(ignored, name) end)
  rescue
    _ -> parts
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
