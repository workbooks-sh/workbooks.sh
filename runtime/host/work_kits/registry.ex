defmodule Workbooks.WorkKits.Registry do
  @moduledoc """
  The on-disk REGISTRY half of `Workbooks.WorkKits` — discovery roots, toolkit
  directory resolution, skill paths (path-contained), runtime entries, and the
  versioned-release index (`releases.json` ∪ manifest VERSION, `.live.json` pins).

  All paths are TRUST-BOUNDARY contained (no `..`/separator traversal escapes the
  toolkit dir); see the `Workbooks.WorkKits` moduledoc for the threat model.
  """
  alias Workbooks.WorkKits.Manifest

  @manifest "manifest.html"
  @skill_ext ".md"

  def manifest_file, do: @manifest
  def skill_ext, do: @skill_ext

  @doc """
  Default discovery root: $WB_WORKKITS_ROOT (validated as an existing dir), else
  the first of workkits/ | ../workkits that exists.
  """
  def default_root do
    env = System.get_env("WB_WORKKITS_ROOT")

    cond do
      is_binary(env) and env != "" and File.dir?(env) -> env
      true -> Enum.find(["workkits", "../workkits", Path.expand("../workkits", File.cwd!())], &File.dir?/1) || "workkits"
    end
  end

  @doc """
  Discover toolkits on disk: read every `<root>/<name>/manifest.html`, parse its
  `<work-ref rel="kit">` self-declaration, and tag the view with its directory.
  """
  def discover_dir(root) do
    Path.wildcard(Path.join(root, "*/#{@manifest}"))
    |> Enum.flat_map(fn manifest ->
      dir = Path.dirname(manifest)

      manifest
      |> File.read!()
      |> Manifest.work_toolkit_nodes()
      |> Enum.map(&Manifest.view/1)
      |> Enum.map(&Map.put(&1, :dir, dir))
    end)
  end

  @doc "Skill names available in a toolkit dir (read the body on demand — progressive disclosure)."
  def skills(toolkit_dir) do
    Path.wildcard(Path.join([toolkit_dir, "skills", "*#{@skill_ext}"]))
    |> Enum.map(&Path.basename(&1, @skill_ext))
    |> Enum.sort()
  end

  @doc "Read a `<work-ref rel=\"kit\">` keyword (UPPER_SNAKE) from a toolkit dir's manifest."
  def manifest_kw(dir, key), do: Manifest.manifest_kw(dir, key, @manifest)

  @doc "Resolve a toolkit id → its on-disk dir, or nil."
  def tk_dir(id, root) do
    case Enum.find(tk_dirs_lite(root), &(&1.id == id)) do
      %{dir: dir} -> dir
      _ -> nil
    end
  end

  # Lightweight toolkit lister: pure filesystem + Floki over the manifest's
  # `<work-ref rel="kit" name=…>`. id = the manifest's `id` attribute, else the dir name.
  def tk_dirs_lite(root) do
    Path.wildcard(Path.join(root, "*/#{@manifest}"))
    |> Enum.map(fn manifest ->
      dir = Path.dirname(manifest)
      id = case Manifest.work_toolkit(File.read!(manifest)) do
             %{attrs: %{"id" => id}} when is_binary(id) and id != "" -> id
             _ -> Path.basename(dir)
           end

      %{id: id, dir: dir}
    end)
  end

  # ── Skill-path safety (slug containment) ───────────────────────────────────

  @slug_re ~r/^[A-Za-z0-9._-]+$/

  defp safe_slug?(slug),
    do: is_binary(slug) and Regex.match?(@slug_re, slug) and slug not in [".", ".."]

  @doc "thin skill: skills/<slug>.md ; thick skill: skills/<slug>/SKILL.md ; nil if unsafe/missing."
  def skill_path(dir, slug) do
    if safe_slug?(slug) do
      skills = Path.join(dir, "skills")
      thin = Path.join([dir, "skills", "#{slug}#{@skill_ext}"])
      thick = Path.join([dir, "skills", slug, "SKILL#{@skill_ext}"])

      cond do
        File.exists?(thin) and contained?(thin, skills) -> thin
        File.exists?(thick) and contained?(thick, skills) -> thick
        true -> nil
      end
    else
      nil
    end
  end

  @doc "Whether `candidate` canonicalizes to a path strictly inside `base` (base or descendant)."
  def contained?(candidate, base) do
    base = Path.expand(base)
    abs = Path.expand(candidate)
    abs == base or String.starts_with?(abs, base <> "/")
  end

  # ── Runtime entries (multi-runtime toolkits) ───────────────────────────────

  @doc """
  A runtime entry is either runtimes/<name>.html (a flat pinned spec, a single
  `<work-ref rel="kit">` island) or runtimes/<name>/manifest.html (a dir carrying
  a build script + assets).
  """
  def runtime_entries(dir) do
    flat =
      Path.wildcard(Path.join([dir, "runtimes", "*.html"]))
      |> Enum.map(fn f -> {Path.basename(f, ".html"), f} end)

    sub =
      Path.wildcard(Path.join([dir, "runtimes", "*", "manifest.html"]))
      |> Enum.map(fn f -> {Path.basename(Path.dirname(f)), f} end)

    flat ++ sub
  end

  # ── Versioned releases ─────────────────────────────────────────────────────

  @doc "Available versions/tags for a toolkit (releases.json ∪ manifest VERSION)."
  def versions_text(id, root) do
    case tk_dir(id, root) do
      nil ->
        "no such toolkit: #{id}"

      dir ->
        live = live_version(id, root)
        vs = available_versions(id, dir, root)

        if vs == [] do
          "#{id}: no versions (add a #+VERSION: to manifest.org or an entry in toolkits/releases.json)"
        else
          "#{id} versions:\n" <>
            Enum.map_join(vs, "\n", fn v ->
              "  #{if v == live, do: "* ", else: "  "}#{v}#{if v == live, do: "  (live)", else: ""}"
            end)
        end
    end
  end

  @doc "The currently-live version — one toolkit (id) or every toolkit's live pin (nil)."
  def live_text(nil, root), do: live_all_text(root)

  def live_text(id, root) do
    case tk_dir(id, root) do
      nil -> "no such toolkit: #{id}"
      dir -> "#{id}: #{live_version(id, root) || manifest_version(dir) || "(no version)"}"
    end
  end

  defp live_all_text(root) do
    case tk_dirs_lite(root) do
      [] ->
        "(no toolkits under #{root})"

      tks ->
        tks
        |> Enum.sort_by(& &1.id)
        |> Enum.map_join("\n", fn t ->
          v = live_version(t.id, root) || manifest_version(t.dir) || "-"
          pinned = if pinned?(t.id, root), do: " (pinned)", else: ""
          "#{String.pad_trailing(t.id, 16)} #{v}#{pinned}"
        end)
    end
  end

  @doc "Set the live version back to an older release (writes/merges the `.live.json` pin)."
  def rollback_text(id, version, root) do
    case tk_dir(id, root) do
      nil ->
        "no such toolkit: #{id}"

      dir ->
        vs = available_versions(id, dir, root)

        cond do
          version in [nil, ""] ->
            "rollback #{id}: no version given (try `work kit versions #{id}`)"

          version not in vs ->
            "rollback #{id}: no such version #{inspect(version)} (have: #{Enum.join(vs, ", ")})"

          true ->
            prev = live_version(id, root)
            write_live_pin(id, version, root)

            "rolled back #{id} → #{version}" <>
              if(prev && prev != version, do: " (was #{prev})", else: "")
        end
    end
  end

  # All known versions for a toolkit: releases.json entry ∪ the in-tree manifest
  # VERSION, newest-first by version sort. Never empty when the manifest declares one.
  defp available_versions(id, dir, root) do
    from_releases =
      case releases(root)[id] do
        vs when is_list(vs) -> Enum.map(vs, &to_string/1)
        %{"versions" => vs} when is_list(vs) -> Enum.map(vs, &to_string/1)
        _ -> []
      end

    ([manifest_version(dir)] ++ from_releases)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> Enum.sort({:desc, Version})
    |> sort_fallback()
  end

  defp sort_fallback(vs) do
    if Enum.all?(vs, &match?({:ok, _}, Version.parse(&1))),
      do: vs,
      else: Enum.sort(vs, :desc)
  end

  defp live_version(id, root), do: live_pins(root)[id]
  defp pinned?(id, root), do: Map.has_key?(live_pins(root), id)
  defp manifest_version(dir), do: manifest_kw(dir, "VERSION")

  defp releases(root), do: read_json(Path.join(root, "releases.json"))
  defp live_pins(root), do: read_json(Path.join(root, ".live.json"))

  defp read_json(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{} = map} <- Jason.decode(body) do
      map
    else
      _ -> %{}
    end
  end

  defp write_live_pin(id, version, root) do
    path = Path.join(root, ".live.json")
    pins = live_pins(root) |> Map.put(id, version)
    File.write!(path, Jason.encode!(pins, pretty: true) <> "\n")
  end
end
