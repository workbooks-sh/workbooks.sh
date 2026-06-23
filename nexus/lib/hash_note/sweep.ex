defmodule Nexus.HashNote.Sweep do
  @moduledoc """
  The **sweep** — the lifecycle pass that collapses drawered (`-#`) hash notes.

  For each `-#` note in a `.work` file the sweep: moves its prose to the `HashNote`
  drawer (a row), and rewrites the source line in place to a `≡<hash>` handle. `+#`
  pinned notes are left untouched on the desk (they live in source; retrieval reads
  them there — no drawer row, so re-sweeps never duplicate them). Lossless: the line
  the note lived on is preserved in git history, so `git show <hash>:<file>` recovers
  it even if the drawer row is later evicted.

  The handle's sha is the *sweep commit* (`ctx.sweep_sha`) — the commit that still
  contains the note live — so the handle doubles as a git ref (see `Nexus.HashNote`).

  Nesting: a `-#` child indented under a `-#` parent gets the parent's handle in its
  `parent` field, so the drawer reflects the source hierarchy. (Cross-sweep roll-up of
  pre-existing handle stacks needs a store update path and is tracked separately.)
  """

  alias Nexus.{Literate, HashNote}

  @summary_len 56

  @doc """
  Collapse drawered notes in `src`. Returns `{new_src, records}` — the rewritten source
  (with `-#` lines turned into `≡<hash>` handles) and the drawer rows to persist. Pure:
  no IO, no store writes. `ctx` carries `:sweep_sha` (required), `:author`, `:born_at`.
  """
  def sweep_source(src, file, ctx) do
    drawered =
      src
      |> Literate.parse()
      |> Enum.filter(&(&1.type == :note and &1.state == :live and &1.polarity == :drawer))

    handles =
      drawered
      |> Enum.with_index()
      |> Map.new(fn {note, i} -> {note.line, HashNote.hash(ctx.sweep_sha, i)} end)

    records =
      Enum.map(drawered, fn note ->
        parent = Map.get(handles, note.parent) || ""

        %{
          hash: Map.fetch!(handles, note.line),
          file: file,
          anchor: note.line,
          text: note.text,
          polarity: :drawer,
          state: :collapsed,
          parent: parent,
          born_at: Map.get(ctx, :born_at, ""),
          swept_at: ctx.sweep_sha,
          author: Map.get(ctx, :author, "")
        }
      end)

    text_by_line = Map.new(drawered, &{&1.line, &1.text})

    new_src =
      src
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {line, n} ->
        case Map.get(handles, n) do
          nil -> line
          handle -> collapse_line(line, handle, Map.fetch!(text_by_line, n))
        end
      end)

    {new_src, records}
  end

  @doc """
  Sweep every `.work` file under `dir`: rewrite drawered notes to handles, persist the
  drawer rows. Returns the count of notes collapsed. `ctx` as in `sweep_source/3` plus an
  optional `:tenant`.
  """
  def sweep_dir(dir, ctx) do
    dir
    |> Path.join("**/*.work")
    |> Path.wildcard()
    |> Enum.reduce(0, fn path, acc ->
      src = File.read!(path)
      {new_src, records} = sweep_source(src, Path.relative_to(path, dir), ctx)

      Enum.each(records, &HashNote.record(&1, Map.get(ctx, :tenant)))
      if new_src != src, do: File.write!(path, new_src)

      acc + length(records)
    end)
  end

  @doc "Register the `sweep` effect (our opinion, on top of the generic Effects engine)."
  def install do
    Nexus.Effects.register("sweep", fn args, _event, ctx ->
      sweep_dir(args[:dir] || File.cwd!(), %{
        sweep_sha: args[:sweep_sha] || "",
        author: args[:author] || "",
        tenant: Map.get(ctx, :tenant)
      })
    end)
  end

  # `-# some prose` → `<indent>≡<hash> <truncated summary>`, preserving the note's indent
  # so a nested note keeps its place in the handle stack.
  defp collapse_line(line, handle, text) do
    indent = Regex.run(~r/^\s*/, line) |> hd()
    summary = String.slice(text, 0, @summary_len)
    summary = if String.length(text) > @summary_len, do: summary <> "…", else: summary
    "#{indent}≡#{handle} #{summary}"
  end
end
