defmodule Workbooks.SitePublish do
  @moduledoc """
  HOST-BROKERED site publish for the keeper agent (Waldo) — wb-9ja.

  The keeper agent authors the live site's content (page sections + blog posts)
  in its git working dir, then makes that content appear on the live page by
  copying it into the host's published static-site root (the same dir
  `Workbooks.PublicWeb` serves from). Waldo used to do this with `cp/mkdir` via
  the deleted native `run` escape hatch; this module is the replacement — a
  TRUSTED HOST capability the agent reaches through the `publish` TOOL.

  ── Why this is NOT the agent executing native code ──────────────────────────
  The whole point of the no-native-exec purge (wb-9ja) is that the AGENT can
  never choose an arbitrary native command line. Here the agent chooses NOTHING
  about how the copy runs: the host owns the source globs (content/**, blog/**),
  the destination (the published site root), and performs the copy with pure
  Elixir `File` ops — no shell, no `cp`, no subprocess. So the dangerous capability
  (run an arbitrary binary) is gone; a constrained, host-defined file copy remains.

  Destination: `<WB_DATA>/build/public/<app>/…` where `<app>` is `WB_PUBLIC_APP`
  (the served app dir for this deployment) or the tenant name. Only the manifest
  files + the section/blog HTML are copied — never source under `src/`, never the
  repo's git/keystore data.
  """

  # Content the agent owns and that the live page loads at runtime. Each entry is
  # {relative-source-glob, dest-subdir}. The host fixes this set; the agent cannot
  # widen it (no path it writes can escape these globs into, say, src/).
  @content_specs [
    {"content/sections.json", "content"},
    {"content/blog.json", "content"},
    {"content/sections/*.html", "content/sections"},
    {"blog/*.html", "blog"}
  ]

  @doc """
  Publish the agent's content from `workdir` to the live public site dir for
  `tenant`. Pure host File ops (no shell). Returns `{:ok, copied_count}` or
  `{:error, reason}`.
  """
  def publish(workdir, tenant) when is_binary(workdir) do
    dest = site_dir(tenant)

    copied =
      Enum.reduce(@content_specs, 0, fn {src_glob, dest_sub}, acc ->
        acc + copy_glob(workdir, src_glob, Path.join(dest, dest_sub))
      end)

    {:ok, copied}
  rescue
    e -> {:error, Exception.message(e)}
  end

  # Copy every file matching `src_glob` (relative to workdir) into `dest_dir`,
  # creating the dir. Path-contained: only files that resolve strictly inside the
  # workdir are copied (a manifest can't smuggle an absolute/`..` path out).
  defp copy_glob(workdir, src_glob, dest_dir) do
    abs_workdir = Path.expand(workdir)

    Path.wildcard(Path.join(abs_workdir, src_glob))
    |> Enum.filter(&File.regular?/1)
    |> Enum.filter(&contained?(abs_workdir, &1))
    |> Enum.reduce(0, fn src, n ->
      File.mkdir_p!(dest_dir)
      File.cp!(src, Path.join(dest_dir, Path.basename(src)))
      n + 1
    end)
  end

  # The published static-site root this deployment serves (mirrors
  # Workbooks.PublicWeb.site_dir/1). The app dir defaults to the tenant; a
  # deployment whose served app name differs sets WB_PUBLIC_APP explicitly.
  defp site_dir(tenant) do
    app = System.get_env("WB_PUBLIC_APP") || to_string(tenant)
    Path.join([System.get_env("WB_DATA") || File.cwd!(), "build", "public", app])
  end

  defp contained?(root, path) do
    String.starts_with?(Path.expand(path) <> "/", Path.expand(root) <> "/")
  end
end
