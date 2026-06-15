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
    probe = if File.exists?(abs), do: abs, else: Path.dirname(abs)
    canon = realpath(probe)

    if canon == workdir or String.starts_with?(canon, workdir <> "/"),
      do: abs,
      else: :escape
  end

  # Best-effort realpath: walk down resolving any symlink component, capped to avoid link cycles.
  defp realpath(path), do: realpath(Path.expand(path), 64)
  defp realpath(path, 0), do: path

  defp realpath(path, fuel) do
    case :file.read_link_all(String.to_charlist(path)) do
      {:ok, target} ->
        t = to_string(target)
        resolved = if String.starts_with?(t, "/"), do: t, else: Path.expand(t, Path.dirname(path))
        realpath(resolved, fuel - 1)

      _ ->
        path
    end
  end
end
