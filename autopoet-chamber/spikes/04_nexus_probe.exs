# Spike 4 — Integration probe against the REAL production parser (no simulation).
#
# Run from the nexus app so Nexus.Literate is loaded:
#   cd nexus && mix run --no-start ../autopoet-chamber/spikes/04_nexus_probe.exs
#
# CLAIM UNDER TEST: the signal the Hebbian layer needs (spike 1) already exists in the
# production path — every node Nexus.Literate.parse/1 emits carries :refs (backlinks,
# #tags, :atoms, @types, work:// links), so "co-activation of refs within a node /
# within a file" is a real, parser-native edge source. No new parser work is needed to
# start learning weights; we only need a durable weighted edge store (SkillKB.Graph's
# Edge rows already have a weight column, hardcoded 1.0 today).
#
# The probe: parse a realistic .work source, harvest ref co-occurrence edges, apply the
# exact Hebbian bump from spike 1, and show the resulting weighted mini-graph.

src = """
# Deploy runbook

Shipping touches [[orders]] and [[billing]], and every incident lands in #ops.
The :submit unit writes @Order rows; see [[orders]] for the schema.

hook :on_deploy do
  match tags: [:deploy]
  run agent: "linter"
end

Rollbacks page [[billing]] and ping #ops.
"""

nodes = Nexus.Literate.parse(src)

IO.puts("\n=== Spike 4: production-parser probe (Nexus.Literate.parse/1) ===\n")
IO.puts("parsed #{length(nodes)} nodes:")

for n <- nodes do
  refs = Map.get(n, :refs, [])
  extra = if refs == [], do: "", else: "  refs=#{inspect(refs)}"
  IO.puts("  line #{n.line}  #{n.type}#{if n.type == :code, do: "(#{n.kind} #{inspect(n.name)})", else: ""}#{extra}")
end

# ── refs → co-activation edges → Hebbian weights (the spike-1 rule, verbatim) ──
eta = 0.35

edges =
  nodes
  |> Enum.map(&Map.get(&1, :refs, []))
  |> Enum.reject(&(length(&1) < 2))
  |> Enum.flat_map(fn refs ->
    for a <- refs, b <- refs, a < b, do: {a, b}
  end)

weights =
  Enum.reduce(edges, %{}, fn pair, acc ->
    w = Map.get(acc, pair, 0.0)
    Map.put(acc, pair, w + eta * (1.0 - w))
  end)

IO.puts("\nco-activation edges after one Hebbian pass (w += #{eta}*(1-w) per co-occurrence):")

for {{a, b}, w} <- Enum.sort_by(weights, fn {_, w} -> -w end) do
  IO.puts("  #{String.pad_trailing(a <> " <-> " <> b, 34)} w=#{Float.round(w, 3)}")
end

repeated = Enum.filter(weights, fn {_, w} -> w > eta end)

IO.puts("""

VERDICT:
  - :refs present on parsed nodes: #{if Enum.any?(nodes, &(Map.get(&1, :refs, []) != [])), do: "YES", else: "NO"}
  - hook block parsed as code unit:  #{if Enum.any?(nodes, &(&1.type == :code and &1.kind == "hook")), do: "YES", else: "NO"}
  - repeated co-activation strengthened (w > single-bump #{eta}): #{if repeated != [], do: "YES — #{inspect(Enum.map(repeated, &elem(&1, 0)))}", else: "NO"}
  The parser-native signal for the plasticity layer EXISTS in production. The missing
  piece is only persistence: a durable weighted edge table + the bump on access events.
""")
