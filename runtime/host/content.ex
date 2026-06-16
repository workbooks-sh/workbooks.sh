defmodule Workbooks.Content do
  @moduledoc """
  Validation for a tenant's runtime-CMS content tree — the host-side check an
  agent runs via `work content check` before publishing. No JS, no node: the
  runtime already reads the tenant repo, so the validator is pure Elixir over
  files. It exists to catch the authoring mistakes that otherwise ship a broken
  page silently — a manifest row with no file, a file with no row (so it never
  appears), a duplicate order, an faq that isn't last, a partial missing its
  section/heading.

  Layout it validates (relative to the working dir, default "."):

    content/sections.json  — [{ order, slug, title, file, pin? }]
    content/sections/*.html — one `<section class="grown">` + one `<h2>` each
    content/blog.json      — [{ slug, title, date, excerpt, tag, file }]
    blog/*.html            — the post pages

  Returns {:ok, summary} | {:error, [problem_strings]}. The CLI prints either.
  """

  def check(dir \\ ".") do
    problems =
      check_sections(dir) ++ check_blog(dir)

    case problems do
      [] -> {:ok, summary(dir)}
      ps -> {:error, ps}
    end
  end

  # ── sections ────────────────────────────────────────────────────────────────

  defp check_sections(dir) do
    manifest = Path.join(dir, "content/sections.json")
    files_dir = Path.join(dir, "content/sections")

    case read_json(manifest) do
      {:error, why} ->
        # No manifest at all is a valid empty site; a malformed one is not.
        if File.exists?(manifest), do: ["content/sections.json: #{why}"], else: []

      {:ok, rows} when is_list(rows) ->
        rows_problems(rows, dir, "section", ["order", "slug", "file"]) ++
          orphans(files_dir, rows, "content/sections") ++
          dup_orders(rows) ++
          faq_last(rows) ++
          Enum.flat_map(rows, &section_shape(dir, &1))

      {:ok, _} ->
        ["content/sections.json: must be a JSON array"]
    end
  end

  # each section partial: exactly one <section class="grown"> and at least one <h2>
  defp section_shape(dir, %{"file" => f}) do
    path = Path.join(dir, f)

    case File.read(path) do
      {:ok, html} ->
        sec = length(Regex.scan(~r/<section\s+class="grown"/, html))
        h2 = length(Regex.scan(~r/<h2[\s>]/, html))

        cond do
          sec != 1 -> ["#{f}: expected exactly one <section class=\"grown\">, found #{sec}"]
          h2 < 1 -> ["#{f}: missing an <h2>"]
          true -> []
        end

      _ ->
        []
    end
  end

  defp section_shape(_, _), do: []

  defp dup_orders(rows) do
    rows
    |> Enum.map(& &1["order"])
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
    |> Enum.filter(fn {_o, n} -> n > 1 end)
    |> Enum.map(fn {o, n} -> "duplicate order #{o} (#{n} sections share it)" end)
  end

  # a pin:"last" (faq) row must have the highest order, or there's ambiguity
  defp faq_last(rows) do
    pinned = Enum.filter(rows, &(&1["pin"] == "last"))
    others = rows -- pinned

    case {pinned, others} do
      {[%{"order" => po, "slug" => slug}], [_ | _]} ->
        max_other = others |> Enum.map(&(&1["order"] || 0)) |> Enum.max()
        if po > max_other, do: [], else: ["#{slug}: pin:\"last\" but its order #{po} isn't the highest — bump it past #{max_other}"]

      _ ->
        []
    end
  end

  # ── blog ────────────────────────────────────────────────────────────────────

  defp check_blog(dir) do
    manifest = Path.join(dir, "content/blog.json")
    blog_dir = Path.join(dir, "blog")

    case read_json(manifest) do
      {:error, why} ->
        if File.exists?(manifest), do: ["content/blog.json: #{why}"], else: []

      {:ok, rows} when is_list(rows) ->
        rows_problems(rows, dir, "post", ["slug", "title", "file"]) ++
          orphans(blog_dir, rows, "blog", ["index.html"])

      {:ok, _} ->
        ["content/blog.json: must be a JSON array"]
    end
  end

  # ── shared ──────────────────────────────────────────────────────────────────

  # every manifest row has its required keys AND its file exists
  defp rows_problems(rows, dir, kind, required) do
    Enum.flat_map(rows, fn row ->
      missing = Enum.reject(required, &Map.has_key?(row, &1))
      id = row["slug"] || row["title"] || "(row)"

      key_p = if missing == [], do: [], else: ["#{kind} #{id}: missing keys #{Enum.join(missing, ", ")}"]

      file_p =
        case row["file"] do
          f when is_binary(f) ->
            if File.exists?(Path.join(dir, f)), do: [], else: ["#{kind} #{id}: file #{f} does not exist"]

          _ ->
            []
        end

      key_p ++ file_p
    end)
  end

  # every file in the dir is referenced by a manifest row (no silent orphans)
  defp orphans(files_dir, rows, prefix, ignore \\ []) do
    referenced = rows |> Enum.map(& &1["file"]) |> Enum.reject(&is_nil/1) |> MapSet.new()

    case File.ls(files_dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".html"))
        |> Enum.reject(&(&1 in ignore))
        |> Enum.map(&"#{prefix}/#{&1}")
        |> Enum.reject(&MapSet.member?(referenced, &1))
        |> Enum.map(&"#{&1}: on disk but has no manifest row (it will never appear) — add it or delete it")

      _ ->
        []
    end
  end

  defp summary(dir) do
    sec = read_json(Path.join(dir, "content/sections.json")) |> count()
    blog = read_json(Path.join(dir, "content/blog.json")) |> count()
    "content ok — #{sec} section(s), #{blog} post(s)"
  end

  defp count({:ok, rows}) when is_list(rows), do: length(rows)
  defp count(_), do: 0

  defp read_json(path) do
    case File.read(path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, data} -> {:ok, data}
          {:error, _} -> {:error, "invalid JSON"}
        end

      {:error, :enoent} ->
        {:error, "not found"}

      {:error, e} ->
        {:error, "#{:file.format_error(e)}"}
    end
  end
end
