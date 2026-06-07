defmodule Workbooks.Private do
  @moduledoc """
  The public/private boundary — ONE source of truth for what is PERSONAL/SESSION
  data and therefore must NOT ship by default when work is shared (committed to
  git, packed into a bundle, or checked out of a Library).

  The rule, stated once: *sharing exposes WORK, never the session that produced
  it.* Telemetry, agent memory, scratch thinking, signing keys, issue-tracker
  exports — none of that travels unless the owner explicitly opts in. This is the
  default that prevents the class of leak we already hit (beads task data pushed
  to GitHub). Every egress path (Git, Bundle, Library) consults THIS module, so
  the boundary can't drift between them.

  Two kinds of private data:
    * FILES/DIRS in a working tree — matched by `private?/1`, and emitted as the
      git-ignore set so they're never committed.
    * VFS VOLUMES inside a container — only `public_volumes/0` ship; `memory`
      (agent long-term memory) and `tmp` stay home.

  Opt-in to include private data is always explicit (`include_private: true`),
  the same shape as the identity toolkit's `--include-private`.
  """

  # Session/personal artifacts in a working tree. Globs + dir prefixes.
  @private_globs ~w(
    _steps.jsonl _status.json _trace.jsonl _telemetry.db _ledger.json
  )
  @private_dirs ~w(scratch/ .workbooks/ .beads/ .claude/)
  # `_*.jsonl|json|db` catches future session sidecars without editing this list.
  @private_prefixes ~w(_)

  # VFS volumes (mirror of Workbooks.VFS). Only @public_volumes ship; the rest
  # (memory, tmp) are private — one list keeps file-form + VFS-form in lockstep.
  @volumes ~w(workspace memory tmp)
  @public_volumes ~w(workspace)

  @doc "Volumes that ship when a container is shared. The rest stay private."
  def public_volumes, do: @public_volumes

  @doc "Is this working-tree path personal/session data (so it must not ship)?"
  def private?(path) do
    base = Path.basename(path)

    Enum.any?(@private_dirs, &String.contains?(path <> "/", &1)) or
      base in @private_globs or
      (String.starts_with?(base, @private_prefixes) and
         String.ends_with?(base, [".jsonl", ".json", ".db"]))
  end

  @doc """
  The git-ignore lines that keep personal/session data out of version control by
  default — written into every tenant repo's `.gitignore` (`Workbooks.Git`). This
  is the automated public/private ignore: the agent (and human) never has to
  remember it.

  Includes the VFS private volumes as directory globs (`memory/`, `tmp/`) so the
  TWO forms of a workbook filesystem stay consistent: if the SQLite VFS is ever
  unpacked to a real tree, the same volumes git already treats as private in the
  file form are ignored there too. One boundary, both forms.
  """
  def gitignore_lines do
    volume_dirs = Enum.map(@volumes -- @public_volumes, &"#{&1}/")
    @private_dirs ++ volume_dirs ++ ["_*.jsonl", "_*.json", "_*.db"]
  end

  @doc "Drop private entries from a parts map (e.g. a Bundle's file set)."
  def strip_parts(parts) when is_map(parts) do
    Map.reject(parts, fn {name, _} -> private?(name) end)
  end
end
