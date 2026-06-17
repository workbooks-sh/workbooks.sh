defmodule Workbooks.WorkKits.Injection do
  @moduledoc """
  The PROMPT-INJECTION half of `Workbooks.WorkKits` — the compact, progressive-
  disclosure TOOLKITS index (`injection_text/2`, Tier-1: WHAT exists + HOW to read
  more, bodies on demand) and the DISCOVERED component catalog (`component_catalog/2`,
  the agent↔component contract, sourced from a component toolkit's CEM).

  The declared toolkit list is first expanded over the dependency graph
  (`Graph.closure_disk/2`) so a toolkit's required toolkits land in the index too.
  """
  alias Workbooks.WorkKits.{Graph, Manifest, Registry}

  @doc """
  The compact TOOLKITS index injected into an agent's system prompt — one short
  entry per declared toolkit (tagline + skill slugs), plus the ONE query pattern
  for going deeper. The skill bodies stay on demand (`work kit show <id> <skill>`).
  """
  def injection_text(names, root) do
    tks = Registry.discover_dir(root) |> Map.new(&{&1.id, &1})
    names = Graph.closure_disk(names, root)

    rows =
      # `acp` is connection-aware and injected by Workbooks.Acp (only when the ACP
      # surface is experimentally enabled), so drop any declared `acp` to avoid a
      # duplicate static row.
      (List.wrap(names) -- ["acp"])
      |> Enum.map(fn id ->
        case tks[id] do
          nil ->
            "- #{id}: (not installed)"

          t ->
            sk = Registry.skills(t.dir)
            {head, rest} = Enum.split(sk, 8)

            skill_line =
              cond do
                head == [] -> ""
                rest == [] -> "\n  skills: " <> Enum.join(head, ", ")
                true -> "\n  skills: " <> Enum.join(head, ", ") <> " (+#{length(rest)} more)"
              end

            "- #{id}: #{Registry.manifest_kw(t.dir, "TAGLINE") || "(no tagline)"}" <> skill_line
        end
      end)

    all = rows ++ Workbooks.Acp.injection_rows()

    if all == [] do
      ""
    else
      """
      ## Work-kits

      You have these work-kits. Before using one, read the relevant skill — call the
      `work` tool: `kit show <id> <skill>` (or `kit search <query>` to find one).

      #{Enum.join(all, "\n")}
      """
      |> String.trim()
    end
  end

  # ── Discovered component catalog (agent↔component contract) ─────────────────
  # When an agent's resolved toolkit closure includes a `#+EXEC: component`
  # toolkit, the chat can render the SDK's real `work-*` custom elements inline.
  # The catalog is DISCOVERED from that toolkit's CEM (`#+CEM` → custom-elements.json),
  # not hardcoded — a compact tag + prop-hint index, lazy on bodies.

  # `work-gen-block` (the chat's inline-card element) multiplexes on its `type`
  # attribute. These are the card kinds gen-block renders today (an unknown type
  # falls back to a labeled code block, so nothing vanishes).
  @gen_block_cards ~w(callout kv button link share)

  @doc """
  The component catalog injected into an agent's prompt when its resolved toolkit
  closure includes a `#+EXEC: component` toolkit. Returns "" when no such toolkit
  is in scope (or its CEM is missing/unreadable).
  """
  def component_catalog([], _root), do: ""

  def component_catalog(names, root) do
    names = Graph.closure_disk(names, root)

    tags =
      names
      |> Enum.flat_map(fn id ->
        case Registry.tk_dir(id, root) do
          nil -> []
          dir -> cem_tags(Manifest.parse_descriptor(File.read!(Path.join(dir, Registry.manifest_file()))), dir, root)
        end
      end)
      |> Enum.uniq_by(& &1.tag)

    case tags do
      [] -> ""
      _ -> render_catalog(tags)
    end
  end

  # Tags discovered from a toolkit's CEM — only for `#+EXEC: component` toolkits
  # that declare a `#+CEM` path. The path resolves relative to the repo root
  # (parent of the toolkits root) first, then the toolkit dir, then as-is.
  defp cem_tags(%{exec: "component", cem: cem}, dir, root) when is_binary(cem) do
    with path when is_binary(path) <- cem_path(cem, dir, root),
         {:ok, raw} <- File.read(path),
         {:ok, %{"modules" => mods}} <- Jason.decode(raw) do
      for m <- mods,
          d <- m["declarations"] || [],
          d["customElement"],
          tag = d["tagName"],
          is_binary(tag) and String.starts_with?(tag, "work-") do
        attrs = for a <- d["attributes"] || [], is_binary(a["name"]), do: a["name"]
        %{tag: tag, attrs: attrs}
      end
    else
      _ -> []
    end
  end

  defp cem_tags(_desc, _dir, _root), do: []

  defp cem_path(cem, dir, root) do
    repo_root = Path.dirname(Path.expand(root))

    [Path.join(repo_root, cem), Path.join(dir, cem), cem]
    |> Enum.find(&File.regular?/1)
  end

  defp render_catalog(tags) do
    by_tag = Map.new(tags, &{&1.tag, &1})

    # The inline-card types the chat renders via <work-gen-block> today. Listed
    # only when the CEM actually carries work-gen-block (the chat's element).
    cards =
      if Map.has_key?(by_tag, "work-gen-block"),
        do: @gen_block_cards,
        else: []

    card_block =
      cards
      |> Enum.map(fn c -> ~s(  <work-gen-block type="#{c}" …>) <> gen_block_hint(c) end)
      |> Enum.join("\n")

    # Every other discovered work-* tag (the standalone elements) + their attrs.
    rest =
      tags
      |> Enum.map(& &1.tag)
      |> Enum.reject(&(&1 == "work-gen-block"))
      |> Enum.sort()

    rest_block =
      rest
      |> Enum.map(fn tag ->
        attrs = by_tag[tag].attrs
        hint = if attrs == [], do: "", else: " — attrs: " <> Enum.join(Enum.take(attrs, 8), ", ")
        "  <#{tag}>#{hint}"
      end)
      |> Enum.join("\n")

    cards_section =
      if card_block == "",
        do: "",
        else: "Inline cards (the `type` attribute selects the card):\n#{card_block}\n\n"

    rest_section =
      if rest_block == "",
        do: "",
        else: "Other `work-*` elements:\n#{rest_block}\n"

    """
    ## Components

    You have a component toolkit. The chat renders the SDK's real `work-*` custom
    elements inline — just write them as HTML anywhere in your reply:

      <work-<tag> attr="value" …>content</work-<tag>>

    The attributes are the element's attributes; the content goes between the tags.
    Reach for a component when a structured/visual answer earns it (you confirmed an
    action, surfaced data, offered a next step); otherwise reply in plain prose.

    DATA BINDING: data elements (chart, table, spark) take their data inline via a
    `rows` attribute — a JSON array of row OBJECTS, e.g.
    `<work-chart type="bar" x="region" y="revenue" rows='[{"region":"NA","revenue":1200}]'>`
    — or `csv` (CSV text with a header row). For a chart, `x`/`y` name the columns and
    `type` is the shape (bar/line/area); a scalar uses `value`/`label`/`delta`. Use
    `from="<name>"` ONLY when a named data source already exists.

    #{cards_section}#{rest_section}
    """
    |> String.trim()
  end

  defp gen_block_hint("callout"), do: " — info/warn/ok/error banner (tone, title)"
  defp gen_block_hint("kv"), do: " — key/value table (title; content = `key: value` lines)"
  defp gen_block_hint("button"), do: " — action button (label, action; fires work-intent)"
  defp gen_block_hint("link"), do: " — themed external link (label, href)"
  defp gen_block_hint("share"), do: " — member chips + invite (title; content = target/members/role)"
  defp gen_block_hint(_), do: ""
end
