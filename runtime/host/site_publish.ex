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
  # The whole content/ and blog/ trees are mirrored RECURSIVELY (structure
  # preserved), not a hardcoded list of globs. The old per-glob list only knew
  # the lander's shape (content/sections/*.html, blog/*.html) and copied ZERO
  # files for bit.ml (content/stories/*.org + stories.json) — the crew's stories
  # had no publish path. Mirroring the trees covers ANY tenant's content shape.
  @publish_trees ["content", "blog"]

  @doc """
  Publish the agent's content from `workdir` to the live public site dir for
  `tenant`. Mirrors content/** + blog/** recursively. Pure host File ops (no
  shell). Returns `{:ok, copied_count}` or `{:error, reason}`.
  """
  def publish(workdir, tenant) when is_binary(workdir) do
    dest = site_dir(tenant)
    abs_workdir = Path.expand(workdir)

    copied =
      Enum.reduce(@publish_trees, 0, fn tree, acc ->
        acc + mirror_tree(abs_workdir, tree, dest)
      end)

    {:ok, copied}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Ship the BUILT app (the tenant repo's `dist/`) to the served site ROOT — the
  "deploy the app" half of publish (content is the other half). A no-op when there
  is no `dist/`: the app build runs in CI and commits `dist` back, OR — the goal —
  the runtime builds it in-sandbox on pull. Clears stale `assets/` first so a
  renamed bundle leaves nothing behind. Returns `{:ok, count}` (0 when no dist).

  Called on GitOps reconcile (a pulled `dist` goes live) and invocable as
  `wb deploy app` — so "commit a built dist" ⇒ "live", the same commit-⇒-live
  invariant content already has.
  """
  def deploy_app(workdir, tenant) when is_binary(workdir) do
    dist = Path.join(Path.expand(workdir), "dist")

    if File.dir?(dist) do
      dest = site_dir(tenant)
      File.mkdir_p!(dest)
      # the built app owns the site ROOT (index.html + assets); content/blog are
      # layered separately by publish/2. Clear old assets so a renamed bundle
      # can't leave stale files served.
      File.rm_rf!(Path.join(dest, "assets"))

      copied =
        Path.wildcard(Path.join(dist, "**"))
        |> Enum.filter(&File.regular?/1)
        |> Enum.reject(&junk?/1)
        |> Enum.reduce(0, fn src, n ->
          rel = Path.relative_to(src, dist)
          dst = Path.join(dest, rel)
          File.mkdir_p!(Path.dirname(dst))
          File.cp!(src, dst)
          n + 1
        end)

      {:ok, copied}
    else
      {:ok, 0}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # Mirror every regular file under workdir/<tree> into dest/<tree>/…, preserving
  # the relative path. Path-contained: only files resolving strictly inside the
  # workdir are copied (a symlink/`..` can't smuggle a path out of the workdir).
  # OS metadata cruft that must never be published: AppleDouble resource forks
  # (`._*`, created when a macOS dev's files cross to a non-HFS volume and which
  # get committed by accident — 22 were polluting bit.ml's served tree) and the
  # usual `.DS_Store`/`Thumbs.db`. They never affect rendering but are junk a
  # crawler would fetch.
  defp junk?(path) do
    base = Path.basename(path)
    String.starts_with?(base, "._") or base in [".DS_Store", "Thumbs.db"]
  end

  defp mirror_tree(abs_workdir, tree, dest) do
    src_root = Path.join(abs_workdir, tree)

    if File.dir?(src_root) do
      Path.wildcard(Path.join(src_root, "**"))
      |> Enum.filter(&File.regular?/1)
      |> Enum.reject(&junk?/1)
      |> Enum.filter(&contained?(abs_workdir, &1))
      |> Enum.reduce(0, fn src, n ->
        rel = Path.relative_to(src, abs_workdir)
        dst = Path.join(dest, rel)
        File.mkdir_p!(Path.dirname(dst))
        File.cp!(src, dst)
        n + 1
      end)
    else
      0
    end
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
