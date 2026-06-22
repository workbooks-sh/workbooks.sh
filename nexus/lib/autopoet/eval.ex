defmodule Nexus.Autopoet.Eval do
  @moduledoc """
  The eval-in-scratch harness (Autopoiesis v2 — wb-a6u3.12). Before the autopoet merges a candidate
  change, it validates it in an ISOLATED scratch copy of the tree — so a bad edit never touches the
  live nexus. `validate/2` takes a change set (`%{relpath => new_source}`), materializes a throwaway
  copy of the workbook's `.work` files with the changes applied, and runs the fast STATIC gates there:

    * **parse** — every changed file still parses (no syntax break),
    * **purity** — no `index.work` smuggled in logic (`Nexus.Index.purity`),
    * **authority** — the change's autonomy classification (`Nexus.Autopoet.Gate`): may the autopoet
      merge it alone, or must a human sign off (a structural-triad touch)?

  Returns a verdict map. `verdict: :pass` means the change is well-formed and safe to *consider*;
  `autonomy: :autonomous | :human_gated` says whether the autopoet may FIFO-merge it or must route to
  a human. The two are orthogonal: a valid grant change is `:pass` + `:human_gated`.

  The static set is side-effect-free (no global agent/hook registration, no wasm build). Heavyweight
  gates — full `Compile.workbook` and LLM `check` units — need process isolation to avoid mutating the
  live registry and are run by the worker out-of-band; the scratch dir is the seam for adding them.
  """

  alias Nexus.{Autopoet.Gate, Index}

  @doc "Validate a `%{relpath => new_source}` change set against `root` in an isolated scratch copy."
  def validate(root, changes) when is_map(changes) do
    scratch = scratch_copy(root)

    try do
      apply_changes(scratch, changes)

      parse_errors = parse_errors(changes)
      impure = Index.purity_tree(scratch)
      {autonomy, reasons} = authority(root, changes)

      verdict = if parse_errors == [] and impure == %{}, do: :pass, else: :fail

      %{
        verdict: verdict,
        autonomy: autonomy,
        reasons: reasons,
        parse_errors: parse_errors,
        impure_indexes: impure,
        scratch: scratch
      }
    after
      File.rm_rf(scratch)
    end
  end

  # Copy the tree's `.work` files (structure preserved) into a throwaway dir — the rest of the tree
  # (build artifacts, node_modules, models) is irrelevant to a static validation and not worth copying.
  defp scratch_copy(root) do
    dest = Path.join(System.tmp_dir!(), "nexus_eval_#{System.unique_integer([:positive])}")

    for f <- work_files(root) do
      target = Path.join(dest, Path.relative_to(f, root))
      File.mkdir_p!(Path.dirname(target))
      File.cp!(f, target)
    end

    dest
  end

  defp work_files(root) do
    (Path.wildcard(Path.join(root, "*.work")) ++ Path.wildcard(Path.join(root, "**/*.work")))
    |> Enum.uniq()
  end

  defp apply_changes(scratch, changes) do
    for {rel, src} <- changes do
      target = Path.join(scratch, rel)
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, src)
    end
  end

  # Each changed source must still parse. A parse that raises (or yields nothing on a non-empty file)
  # is a syntax break — the kind of thing a careless autopoet edit could introduce.
  defp parse_errors(changes) do
    for {rel, src} <- changes, parse_broken?(src), do: rel
  end

  defp parse_broken?(src) do
    Nexus.Literate.parse(src)
    false
  rescue
    _ -> true
  end

  # Aggregate authority across the change set: the per-change Gate triad check (grant/ceiling/management
  # on the change itself) PLUS the SUBTREE management posture from the index hierarchy (wb-a6u3.15 — an
  # app/agent under a frozen/proposed subtree is not autonomously editable, even for a benign edit). If
  # ANY change needs a human, the whole set does.
  defp authority(root, changes) do
    reasons =
      Enum.flat_map(changes, fn {rel, new_src} ->
        old_src = read_old(root, rel)

        gate =
          case Gate.classify(rel, old_src, new_src) do
            {:autonomous, []} -> []
            {:human_gated, rs} -> rs
          end

        gate ++ subtree_reasons(root, rel)
      end)
      |> Enum.uniq()

    if reasons == [], do: {:autonomous, []}, else: {:human_gated, reasons}
  end

  defp subtree_reasons(root, rel) do
    dir = Path.dirname(Path.join(root, rel))

    case Nexus.Index.effective_management(root, dir) do
      "managed" -> []
      posture -> [{:subtree_management, posture}]
    end
  end

  defp read_old(root, rel) do
    path = Path.join(root, rel)
    if File.exists?(path), do: File.read!(path), else: ""
  end
end
