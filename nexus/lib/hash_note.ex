defmodule Nexus.HashNote do
  @moduledoc """
  The **drawer + dereference spine** for hash notes (the `+#`/`-#`/`≡<hash>` lane in
  `Nexus.Literate`). A swept `-#` note collapses to a `≡<hash>` handle in source; its
  prose moves to the `HashNote` resource (the hot drawer). Git is the cold backstop —
  the note was a real line once, so `git show <hash>` recovers it even after the row is
  evicted. This module owns three things:

    * **the handle format** — `hash/2`: a short prefix of the *sweep commit sha* (so a
      handle is a real git ref), suffixed per-note when several collapse in one sweep.
    * **the resource shape** — compiled from `priv/work/hash_note.work` (the dogfooded
      single source of truth for the columns), reachable as the `HashNote` module.
    * **dereference** — `expand/2`: hot store row first, else `git show <ref>` (cold).

  The whole point is losslessness: nothing the sweep does destroys a note, it only
  moves it down the ladder desk → drawer → git.
  """

  @sha_len 7

  @doc """
  The `≡` handle for a note swept in commit `sweep_sha`. `index` disambiguates several
  notes collapsing in the SAME sweep (0 ⇒ bare sha prefix; n>0 ⇒ `<sha>.<base36>`). The
  git-meaningful part is always the leading sha prefix — see `git_ref/1`.
  """
  def hash(sweep_sha, index \\ 0) do
    base = sweep_sha |> to_string() |> String.slice(0, @sha_len)
    if index > 0, do: base <> "." <> String.downcase(Integer.to_string(index, 36)), else: base
  end

  @doc "The git ref embedded in a handle — the part before the per-note suffix. `git show <this>` works."
  def git_ref(handle), do: handle |> to_string() |> String.split(".") |> hd()

  @doc "The compiled `HashNote` resource module (drawer shape). Ensures it's loaded from the .work source."
  def resource_mod do
    ensure()
    Nexus.Uid.module("HashNote")
  end

  @doc "Persist a collapsed note into the drawer. `attrs` are the resource fields (must include `:hash`)."
  def record(attrs, tenant \\ nil) do
    mod = resource_mod()
    if tenant, do: Nexus.Store.create(mod, attrs, tenant), else: Nexus.Store.create(mod, attrs)
  end

  @doc "The drawer row for `handle`, or `nil`."
  def fetch(handle, tenant \\ nil) do
    mod = resource_mod()
    rows = if tenant, do: Nexus.Store.all(mod, tenant), else: Nexus.Store.all(mod)
    Enum.find(rows, &(&1.hash == handle))
  end

  @doc """
  Dereference a handle along the durability ladder: the hot drawer row first, then the
  git cold backstop (`git show <ref>` in `:dir`, default cwd). Returns
  `{:ok, %{... , source: :drawer | :archive}}` or `{:error, :not_found}`.
  """
  def expand(handle, opts \\ []) do
    tenant = opts[:tenant]

    case fetch(handle, tenant) do
      nil -> from_git(handle, opts[:dir] || File.cwd!())
      row -> {:ok, row |> Map.from_struct() |> Map.put(:source, :drawer)}
    end
  end

  @doc """
  Drawered notes anchored near `file` — the hidden "why-not / caution" context a prior
  edit collapsed out of source. Exact-file matches rank above same-directory ones, then by
  anchor line. These are what an agent can't see (the source only has `≡<hash>` handles),
  so they're the high-value thing to surface before it edits.
  """
  def notes_near(file, tenant \\ nil) do
    mod = resource_mod()
    rows = if tenant, do: Nexus.Store.all(mod, tenant), else: Nexus.Store.all(mod)
    file = to_string(file)
    dir = Path.dirname(file)

    rows
    |> Enum.map(&{proximity(to_string(&1.file), file, dir), &1})
    |> Enum.filter(fn {s, _} -> s > 0 end)
    |> Enum.sort_by(fn {s, r} -> {-s, r.anchor} end)
    |> Enum.map(&elem(&1, 1))
  end

  defp proximity(rfile, file, dir) do
    cond do
      rfile == file -> 2
      Path.dirname(rfile) == dir -> 1
      true -> 0
    end
  end

  @doc """
  Build the agent context preamble for `files` — a `-#`/collapsed-notes briefing to inject
  before a run, or `nil` when there are no nearby notes. Pure over the drawer.
  """
  def preamble(files, tenant \\ nil) do
    notes =
      files
      |> List.wrap()
      |> Enum.flat_map(&notes_near(&1, tenant))
      |> Enum.uniq_by(& &1.hash)

    case notes do
      [] ->
        nil

      list ->
        body =
          Enum.map_join(list, "\n", fn n -> "  • ≡#{n.hash} (#{n.file}:#{n.anchor}) — #{n.text}" end)

        "## Hash notes near your work — collapsed context from prior edits.\n" <>
          "Cautions / why-not decisions an earlier agent drawered out of source. Read them BEFORE " <>
          "editing; re-expand any with `work note expand <hash>`.\n" <> body
    end
  end

  @doc "Children of a parent handle (the rolled-up stack), in stored order. `[]` if none."
  def children(parent_handle, tenant \\ nil) do
    mod = resource_mod()
    rows = if tenant, do: Nexus.Store.all(mod, tenant), else: Nexus.Store.all(mod)
    Enum.filter(rows, &(&1.parent == parent_handle))
  end

  # ── git cold backstop ───────────────────────────────────────────────────────
  # The handle's sha prefix names the sweep commit that collapsed the note. That commit's
  # diff removed the `+#`/`-#` line from source, so the removed note text is recoverable
  # from `git show`. Best-effort: return the first removed note line found.
  defp from_git(handle, dir) do
    ref = git_ref(handle)

    case System.cmd("git", ["show", ref], cd: dir, stderr_to_stdout: true) do
      {out, 0} ->
        case archived_note_text(out) do
          nil -> {:error, :not_found}
          text -> {:ok, %{hash: handle, text: text, source: :archive}}
        end

      _ ->
        {:error, :not_found}
    end
  end

  # A removed hash-note line in a unified diff: `-` (diff marker) then `+#`/`-#` (note marker).
  defp archived_note_text(diff) do
    diff
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case Regex.run(~r/^-\s*[+-]#\s?(.*)$/, line) do
        [_, text] -> String.trim(text)
        _ -> nil
      end
    end)
  end

  # ── resource shape (dogfooded from priv/work/hash_note.work) ─────────────────
  defp ensure do
    mod = Nexus.Uid.module("HashNote")

    unless Code.ensure_loaded?(mod) and function_exported?(mod, :__fields__, 0) do
      :nexus
      |> Application.app_dir("priv/work/hash_note.work")
      |> File.read!()
      |> Nexus.Literate.parse()
      |> Enum.find(&(&1.type == :code and &1.kind == "resource"))
      |> Nexus.Resource.compile()
    end

    :ok
  end
end
