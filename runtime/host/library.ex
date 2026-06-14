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
    # Federation (wb-39j): if the FROM names a registered data source, route to the
    # plugin; otherwise fall through to the local VFS query over workspace members.
    case Workbooks.Federation.query(sql) do
      {:ok, rows} -> %{rows: [%{member: "federation", workspace: nil, rows: rows}], skipped: [], federated: true}
      {:error, reason} -> %{rows: [], skipped: [], error: inspect(reason)}
      :not_federated -> vfs_query(tenant, sql)
    end
  end

  defp vfs_query(tenant, sql) do
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
  PACK a workspace and STORE the resulting workbook on the configured backend
  (`Workbooks.Storage` — local volume / S3 / R2, per deploy). Durable across
  redeploys; tenant-scoped. Returns {:ok, key} (the storage key) or {:error, _}.
  opts pass through to `pack/3` (build:, purpose:, only:).
  """
  def store(tenant, workspace_slug, opts \\ []) do
    case pack(tenant, workspace_slug, opts) do
      {:ok, blob} ->
        key = "workbooks/#{workspace_slug}.wbundle"
        case Workbooks.Storage.put(tenant, key, blob) do
          :ok ->
            # Index for semantic search at store time (best-effort — storage is
            # the durable record; the index is rebuildable via index/2).
            unless opts[:no_index], do: index(tenant, workspace_slug)
            {:ok, key}

          err -> err
        end

      err -> err
    end
  end

  @doc "Fetch a stored workbook's bytes by key (from the configured backend)."
  def fetch(tenant, key), do: Workbooks.Storage.get(tenant, key)

  @doc """
  Index a workspace for semantic search — chunk each member (org by section, code
  by line-window), embed the chunks (`Workbooks.Embed`, batched), and upsert the
  vectors (`Workbooks.Vector`) tagged {workbook, path, headline}. Re-indexable
  (forgets the workspace's prior vectors first). Returns {:ok, chunk_count}.
  Called automatically by `store/3`; embed happens at STORE time, not query time.
  """
  def index(tenant, workspace_slug, _opts \\ []) do
    case Enum.find(workspaces(tenant), &(&1.slug == workspace_slug)) do
      nil -> {:error, "no such workspace: #{workspace_slug}"}
      ws ->
        repo = Git.repo_path(tenant)
        Workbooks.Vector.forget(tenant, workspace_slug)

        chunks =
          ws.members
          |> Enum.flat_map(fn
            %{ref: {:path, p}} -> vendor(repo, p)
            # Cross-workbook by DID (4b): resolve the referenced workbook + index
            # its content too — federated query against the identity. Best-effort.
            %{ref: {:did, did}, id: id} ->
              case Workbooks.Did.resolve(did), do: ({:ok, b} -> [{"#{id}.html", b}]; _ -> [])

            _ -> []
          end)
          |> Enum.filter(fn {name, _} -> text_file?(name) end)
          |> Enum.flat_map(fn {name, content} ->
            chunk(name, content)
            |> Enum.with_index()
            |> Enum.map(fn {{headline, text}, i} ->
              %{id: "#{workspace_slug}:#{name}:#{i}", text: text,
                meta: %{workbook: workspace_slug, path: name, headline: headline, text: text}}
            end)
          end)

        case chunks do
          [] -> {:ok, 0}
          _ ->
            # Embed failures (e.g. WB_EMBED=local but the model can't download) are
            # returned cleanly — never a MatchError that crashes the caller process.
            case Workbooks.Embed.embed(Enum.map(chunks, & &1.text)) do
              {:ok, vectors} ->
                Enum.zip(chunks, vectors) |> Enum.each(fn {c, v} -> Workbooks.Vector.upsert(tenant, c.id, v, c.meta) end)
                {:ok, length(chunks)}

              {:error, e} -> {:error, "embed failed: #{e}"}
            end
        end
    end
  end

  @doc """
  Search the tenant's indexed workbooks — a CONSUMER-AGNOSTIC query surface (any
  script/service/agent calls it; no LLM assumed). HYBRID by default: a semantic
  pass (vector cosine) fused with a literal pass (query-term overlap) via
  reciprocal-rank-fusion — semantic finds meaning, literal pins exact terms,
  fusion gets both. opts: :k, :workbook / :workbooks (scope), :mode
  (:hybrid | :semantic | :literal). Returns ranked %{path, headline, text, ...}.
  """
  def search(tenant, query, opts \\ []) do
    k = opts[:k] || 5
    mode = opts[:mode] || :hybrid

    with {:ok, qvec} <- Workbooks.Embed.embed(query) do
      search_with(tenant, qvec, query, k, mode, opts)
    else
      # Embedder unavailable → no semantic results (clean empty, never a crash).
      {:error, _} -> []
    end
  end

  defp search_with(tenant, qvec, query, k, mode, opts) do
    pool = Workbooks.Vector.search(tenant, qvec, Keyword.merge(opts, k: 50))
    terms = query |> String.downcase() |> String.split(~r/\W+/, trim: true) |> Enum.reject(&(&1 == ""))

    ranked =
      case mode do
        :semantic -> pool
        :literal -> Enum.sort_by(pool, &lex_score(&1.text, terms), :desc)
        _ -> rrf(pool, Enum.sort_by(pool, &lex_score(&1.text, terms), :desc))
      end

    Enum.take(ranked, k)
  end

  defp lex_score(text, terms) do
    t = String.downcase(text || "")
    Enum.count(terms, &String.contains?(t, &1))
  end

  # Reciprocal-rank fusion of two rankings (by chunk id). RRF score = Σ 1/(60+rank).
  defp rrf(rank_a, rank_b) do
    idx = fn list -> list |> Enum.with_index() |> Map.new(fn {h, i} -> {h.id, i} end) end
    a = idx.(rank_a)
    b = idx.(rank_b)

    (Map.keys(a) ++ Map.keys(b))
    |> Enum.uniq()
    |> Enum.map(fn id ->
      hit = Enum.find(rank_a, &(&1.id == id)) || Enum.find(rank_b, &(&1.id == id))
      score = 1 / (60 + Map.get(a, id, 1000)) + 1 / (60 + Map.get(b, id, 1000))
      Map.put(hit, :rrf, score)
    end)
    |> Enum.sort_by(& &1.rrf, :desc)
  end

  @doc """
  Semantic recall over a directory's org/code files — STATELESS (chunk + embed +
  rank on the fly, no stored index). This is "memory" reframed: there is no
  separate note store to drift; you search the actual org/code context the agent
  is working in, so results always reflect the CURRENT files. Returns ranked
  %{path, headline, text, score}. opts: :k.
  """
  def search_dir(dir, query, opts \\ []) do
    chunks =
      dir
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.filter(&text_file?(&1))
      |> Enum.flat_map(fn f ->
        chunk(Path.basename(f), File.read!(f))
        |> Enum.map(fn {hl, text} -> %{path: Path.relative_to(f, dir), headline: hl, text: text} end)
      end)

    with [_ | _] <- chunks,
         {:ok, [qvec]} <- Workbooks.Embed.embed([query]),
         {:ok, vecs} <- Workbooks.Embed.embed(Enum.map(chunks, & &1.text)) do
      Enum.zip(chunks, vecs)
      |> Enum.map(fn {c, v} -> Map.put(c, :score, Workbooks.Embed.cosine(qvec, v)) end)
      |> Enum.sort_by(& &1.score, :desc)
      |> Enum.take(opts[:k] || 5)
    else
      # No content at all → nothing to recall.
      [] -> []
      # Embeddings unavailable (key rotation / outage / rate limit): degrade to a
      # keyword fallback over the chunks we DID read, so the agent's recall still
      # works instead of silently returning "(no relevant context)".
      _ -> literal_rank(chunks, query, opts[:k] || 5)
    end
  end

  # Substring/term-overlap ranking — the embeddings-down fallback for search_dir.
  defp literal_rank(chunks, query, k) do
    terms = query |> String.downcase() |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)

    chunks
    |> Enum.map(fn c -> Map.put(c, :score, term_hits(String.downcase(c.text), terms)) end)
    |> Enum.filter(&(&1.score > 0))
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(k)
  end

  defp term_hits(_hay, []), do: 0
  defp term_hits(hay, terms), do: Enum.count(terms, &String.contains?(hay, &1))

  @doc false
  # test seam for the embeddings-down keyword fallback
  def literal_rank_for_test(chunks, query, k), do: literal_rank(chunks, query, k)

  @text_exts ~w(.org .md .txt .rs .js .ts .jsx .tsx .svelte .ex .exs .py .go .html .css .sql .json .toml .yaml .yml)
  defp text_file?(name), do: Path.extname(name) in @text_exts

  # Org → one chunk per heading section (heading + body); other text → line windows.
  defp chunk(name, content) do
    if String.ends_with?(name, ".org"), do: org_sections(content), else: line_windows(content, 20)
  end

  defp org_sections(content) do
    Regex.split(~r/^(?=\*+ )/m, content, trim: true)
    |> Enum.map(fn sec ->
      headline = sec |> String.split("\n", parts: 2) |> hd() |> String.replace(~r/^\*+\s*/, "") |> String.replace(~r/\s+:[\w:]+:\s*$/, "") |> String.trim()
      {headline, String.trim(sec)}
    end)
    |> Enum.reject(fn {_, t} -> t == "" end)
  end

  defp line_windows(content, n) do
    content
    |> String.split("\n")
    |> Enum.chunk_every(n)
    |> Enum.with_index()
    |> Enum.map(fn {lines, i} -> {"lines #{i * n + 1}–#{i * n + length(lines)}", Enum.join(lines, "\n")} end)
    |> Enum.reject(fn {_, t} -> String.trim(t) == "" end)
  end

  @doc "List the tenant's stored workbooks (keys on the configured backend)."
  def stored(tenant), do: Workbooks.Storage.list(tenant, "workbooks")

  @doc """
  Index an IMAGE (url/path/base64) for cross-modal search — embed it with the
  image embedder (CLIP, one text+image space) and upsert into the `images` scope.
  Returns :ok | {:error, _}.
  """
  def index_image(tenant, id, image, meta \\ %{}) do
    case Workbooks.Embed.embed(image, :image) do
      {:ok, vec} ->
        Workbooks.Vector.upsert(tenant, "image:#{id}", vec, Map.merge(%{workbook: "images", path: id, headline: meta[:caption] || id}, meta))
        :ok

      err -> err
    end
  end

  @doc """
  Cross-modal image search — a TEXT query finds the most similar IMAGES. The query
  is embedded in the image embedder's space (CLIP-text), so it matches the stored
  image vectors. Returns ranked %{path, score, ...} or {:error, _}.
  """
  def search_images(tenant, query, opts \\ []) do
    case Workbooks.Embed.embed_query_for(:image, query) do
      {:ok, qvec} -> Workbooks.Vector.search(tenant, qvec, Keyword.merge(opts, workbook: "images"))
      err -> err
    end
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
  INSTALL a toolkit-workbook (wb-rhs.7): register the compiled command artifacts a
  workbook bundle carries so `run-command` finds them — the one verb the toolkit
  registry needs that the workbook rails don't already provide. Everything else
  (publish=store/3, search=search/3, sign=Bundle.ship, share=DID member) is reuse;
  there is NO separate toolkit package format — a toolkit IS a workbook.

  A packed-with-build workbook carries its commands as `<name>.wasm` parts (the
  build projection, pack/3 `build: true`). Install writes each to the
  content-addressed store and registers it. Each registered command is capped by
  the Instance Policy profile like any other — installing never widens caps.

  SUPPLY-CHAIN GATE: pass `sha:` to PIN the bundle — `sha256(blob)` must equal it
  before anything is trusted/registered (mirrors fetch_and_register_wasm's pin and
  the third-party trust posture). Returns `{:ok, %{commands: [name]}}`.
  """
  def install(blob, opts \\ []) when is_binary(blob) do
    with :ok <- pin_ok(blob, opts[:sha]),
         :ok <- sig_ok(blob, opts[:require_signature]) do
      parts = Workbooks.Bundle.unpack(blob)
      tmp = Path.join(System.tmp_dir!(), "wb-install-#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(tmp)

      try do
        # Accumulate {:ok, names} | {:error, reason}; once an error appears,
        # later iterations pass it through unchanged (comprehensions can't break).
        result =
          for {name, bytes} <- parts, String.ends_with?(name, ".wasm"), reduce: {:ok, []} do
            {:ok, acc} ->
              cmd = Path.basename(name, ".wasm")
              wasm = Path.join(tmp, "#{cmd}.wasm")
              File.write!(wasm, bytes)

              case Workbooks.CommandRegistry.register_artifact(cmd, wasm) do
                {:ok, _addressed} -> {:ok, [cmd | acc]}
                {:error, reason} -> {:error, {:register_failed, cmd, reason}}
              end

            {:error, _} = err ->
              err
          end

        case result do
          {:ok, names} -> {:ok, %{commands: Enum.reverse(names)}}
          {:error, _} = err -> err
        end
      after
        File.rm_rf(tmp)
      end
    end
  end

  defp pin_ok(_blob, nil), do: :ok

  defp pin_ok(blob, expected) when is_binary(expected) do
    actual = :crypto.hash(:sha256, blob) |> Base.encode16(case: :lower)
    if actual == expected, do: :ok, else: {:error, :sha_mismatch}
  end

  # Optional signature gate (wb-pkh.9): a third-party/signed toolkit-workbook must
  # carry a valid embedded signature (Bundle.verify → Manifest.verify over the
  # workbook.html) before anything is registered. Off by default (first-party local
  # installs need no signature); pass `require_signature: true` for the
  # third-party trust posture.
  defp sig_ok(_blob, sig) when sig in [nil, false], do: :ok

  defp sig_ok(blob, true) do
    case Workbooks.Bundle.verify(blob) do
      %{valid: true} -> :ok
      %{valid: false} = v -> {:error, {:bad_signature, v}}
      %{error: e} -> {:error, {:unverifiable, e}}
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
