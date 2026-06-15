defmodule Workbooks.WorkdirConfine do
  @moduledoc """
  Shared workdir confinement for the brokered-FS surfaces (the SM-lane fetch loopback `Workbooks.ExecLoopback`
  AND the synchronous host-import `Workbooks.HostBroker`). Both confine every guest fs path INSIDE the grant's
  `:workdir` and refuse any escape (`..`, absolute, or a symlink whose target leaves the workdir). Factored out
  of ExecLoopback so the two transports share ONE confinement implementation (DRY — the security spine is the
  same regardless of whether the op arrived over guest fetch() or the sync import).
  """

  @doc """
  Resolve `raw` INSIDE `workdir`, refusing any escape. A path is treated as workdir-relative (a leading "/"
  is stripped so an "absolute" guest path still lands in the workdir); `..` segments that would climb above
  the workdir are rejected. The final real path (symlinks resolved on the existing prefix) must still be a
  prefix-descendant of the workdir. Returns `{:ok, abs}` | `{:error, :escape}`.
  """
  def confine(workdir, raw) when is_binary(raw) and raw != "" do
    rel = String.trim_leading(raw, "/")

    case Path.safe_relative(rel) do
      {:ok, safe} ->
        abs = Path.expand(safe, workdir)

        if abs == workdir or String.starts_with?(abs, workdir <> "/") do
          case no_symlink_escape(workdir, abs) do
            :escape -> {:error, :escape}
            ok_abs -> {:ok, ok_abs}
          end
        else
          {:error, :escape}
        end

      :error ->
        {:error, :escape}
    end
  end

  def confine(_workdir, _raw), do: {:error, :escape}

  # Canonicalize the nearest EXISTING ancestor of `abs` (resolving every symlink component) and verify it is
  # still inside the workdir — so a symlink planted inside the workdir can't be used to read/write OUTSIDE it.
  defp no_symlink_escape(workdir, abs) do
    # Canonicalize BOTH sides: the workdir itself may sit under a symlinked ancestor (e.g. macOS
    # /var -> /private/var, or /tmp), so the resolved `abs` must be compared against the resolved
    # root, not the raw workdir, or every legit path would falsely read as an escape.
    root = realpath(workdir)
    probe = if File.exists?(abs), do: abs, else: Path.dirname(abs)
    canon = realpath(probe)

    if canon == root or String.starts_with?(canon, root <> "/"),
      do: abs,
      else: :escape
  end

  # Canonicalize `path` by resolving EVERY symlink component — not just the leaf — walking from the
  # filesystem root down. A leaf-only resolve (the prior impl) missed an INTERMEDIATE DIRECTORY symlink:
  # `<root>/link -> <other-tenant>` then reading `link/file` left `link` unresolved (read_link on the full
  # path is :einval for a regular leaf), so it passed the prefix check and escaped. Resolving per-component
  # closes that. Capped (fuel) to avoid symlink cycles; a component with no link is taken literally.
  defp realpath(path) do
    [_root | segs] = Path.split(Path.expand(path))
    resolve(segs, "/", 64)
  end

  defp resolve(_segs, acc, 0), do: acc
  defp resolve([], acc, _fuel), do: acc

  defp resolve([seg | rest], acc, fuel) do
    joined = if acc == "/", do: "/" <> seg, else: acc <> "/" <> seg

    case :file.read_link_all(String.to_charlist(joined)) do
      {:ok, target} ->
        t = to_string(target)
        base = if String.starts_with?(t, "/"), do: t, else: Path.join(Path.dirname(joined), t)
        # Re-resolve the (possibly relative, possibly itself-symlinked) target from the root, then
        # continue with the remaining segments — so chained/relative dir symlinks resolve too.
        [_root | newsegs] = Path.split(Path.expand(base))
        resolve(newsegs ++ rest, "/", fuel - 1)

      _ ->
        resolve(rest, joined, fuel)
    end
  end
end
