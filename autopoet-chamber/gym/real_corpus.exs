# Real-corpus prior harvest — does the cold-start prior hold at REAL scale?
# Walks every .work file in the repo (the actual dogfood/docs/skills/templates corpora,
# not gym-generated docs), parses each with the production parser, and measures the
# authored graph a fresh nexus would be born with: coverage (how many files even carry
# refs), edge counts, hubs, and the co-activation edge list the Hebbian layer would
# initialize from.
#
# Run:  cd nexus && mix run --no-start ../autopoet-chamber/gym/real_corpus.exs [root]

root =
  case System.argv() do
    [r | _] -> Path.expand(r)
    [] -> Path.expand("../..", __DIR__)
  end

exclude = ~w(/_build/ /deps/ /node_modules/ /.git/ /.jj/ /.nexus/ /vendor/)

files =
  Path.wildcard(Path.join(root, "**/*.work"))
  |> Enum.reject(fn f -> Enum.any?(exclude, &String.contains?(f, &1)) end)

parsed =
  for f <- files do
    try do
      nodes = Nexus.Literate.parse(File.read!(f))
      refs_per_node = Enum.map(nodes, &Map.get(&1, :refs, []))
      {:ok, f, refs_per_node}
    rescue
      _ -> {:error, f}
    end
  end

ok = for {:ok, f, r} <- parsed, do: {f, r}
failures = for {:error, f} <- parsed, do: f

all_refs = ok |> Enum.flat_map(fn {_, per_node} -> List.flatten(per_node) end)
files_with_refs = Enum.count(ok, fn {_, per_node} -> List.flatten(per_node) != [] end)

# co-activation edges: refs co-occurring within one node (the spike-4 rule)
edges =
  ok
  |> Enum.flat_map(fn {_, per_node} -> per_node end)
  |> Enum.reject(&(length(&1) < 2))
  |> Enum.flat_map(fn refs -> for a <- refs, b <- refs, a < b, do: {a, b} end)

distinct_edges = edges |> Enum.uniq()
edge_counts = edges |> Enum.frequencies()

degree =
  distinct_edges
  |> Enum.flat_map(fn {a, b} -> [a, b] end)
  |> Enum.frequencies()

by_dir =
  ok
  |> Enum.group_by(fn {f, _} -> f |> Path.relative_to(root) |> Path.split() |> hd() end)
  |> Enum.map(fn {dir, fs} ->
    refs = Enum.flat_map(fs, fn {_, per_node} -> List.flatten(per_node) end)
    {dir, length(fs), length(refs)}
  end)
  |> Enum.sort_by(fn {_, _, r} -> -r end)

IO.puts("\n=== real-corpus prior harvest: #{root} ===\n")
IO.puts("files parsed: #{length(ok)}   parse failures: #{length(failures)}")
IO.puts("ref coverage: #{files_with_refs}/#{length(ok)} files carry >=1 ref (#{Float.round(100 * files_with_refs / max(length(ok), 1), 1)}%)")
IO.puts("refs total: #{length(all_refs)}   distinct tokens: #{all_refs |> Enum.uniq() |> length()}")
IO.puts("co-activation edges: #{length(distinct_edges)} distinct (#{length(edges)} occurrences)")

IO.puts("\nper top-level dir (files | refs):")
for {dir, nf, nr} <- Enum.take(by_dir, 10), do: IO.puts("  #{String.pad_trailing(dir, 22)} #{String.pad_leading(to_string(nf), 5)} | #{nr}")

IO.puts("\ntop hubs (degree in the authored graph):")
for {tok, d} <- degree |> Enum.sort_by(fn {_, d} -> -d end) |> Enum.take(10), do: IO.puts("  #{String.pad_trailing(tok, 34)} #{d}")

IO.puts("\nstrongest authored co-activations (would seed the highest prior weights):")
for {{a, b}, c} <- edge_counts |> Enum.sort_by(fn {_, c} -> -c end) |> Enum.take(8) do
  IO.puts("  #{String.pad_trailing(a <> " <-> " <> b, 44)} x#{c}")
end

if failures != [] do
  IO.puts("\nparse failures (first 5):")
  for f <- Enum.take(failures, 5), do: IO.puts("  #{Path.relative_to(f, root)}")
end

# ── ref-class breakdown + the NAVIGATION prior ──────────────────────────────────────
# :atom mentions are dominated by enum values (:ok, :low, :moderate…) — stopword-like,
# high frequency, low information. Deliberate navigation acts ([[backlink]], #tag,
# work://) are the high-signal class; the production prior should seed from THESE
# (optionally adding idf-weighted atoms later).
class = fn
  "[[" <> _ -> :backlink
  "#" <> _ -> :tag
  "work://" <> _ -> :worklink
  "@" <> _ -> :type
  _ -> :atom
end

IO.puts("\nref classes: #{all_refs |> Enum.frequencies_by(class) |> inspect()}")

# hex colors in styled blocks parse as #tags (parser hygiene gap — filed); exclude them
hex? = fn tok -> Regex.match?(~r/^#[0-9a-f]{3,8}$/, tok) end
nav? = fn tok -> class.(tok) in [:backlink, :tag, :worklink] and not hex?.(tok) end

nav_edges =
  ok
  |> Enum.flat_map(fn {_, per_node} -> per_node end)
  |> Enum.map(fn refs -> Enum.filter(refs, nav?) end)
  |> Enum.reject(&(length(&1) < 2))
  |> Enum.flat_map(fn refs -> for a <- refs, b <- refs, a < b, do: {a, b} end)

nav_distinct = Enum.uniq(nav_edges)
nav_files = Enum.count(ok, fn {_, per_node} -> per_node |> List.flatten() |> Enum.any?(nav?) end)

nav_degree =
  nav_distinct |> Enum.flat_map(fn {a, b} -> [a, b] end) |> Enum.frequencies()

IO.puts("\nNAVIGATION PRIOR ([[backlink]]/#tag/work:// only):")
IO.puts("  coverage: #{nav_files}/#{length(ok)} files (#{Float.round(100 * nav_files / max(length(ok), 1), 1)}%)")
IO.puts("  distinct edges: #{length(nav_distinct)} (#{length(nav_edges)} occurrences)")
IO.puts("  top hubs:")

for {tok, d} <- nav_degree |> Enum.sort_by(fn {_, d} -> -d end) |> Enum.take(8),
    do: IO.puts("    #{String.pad_trailing(tok, 34)} #{d}")

IO.puts("")
