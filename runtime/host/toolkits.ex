defmodule Workbooks.Toolkits do
  @moduledoc """
  Toolkit discovery (L4, wb-11ck.46) — the agent extensibility surface. A toolkit
  makes an agent competent with a CLI it has never seen: a single `<work-toolkit>`
  HTML element (the `manifest.html` front-door) names the CLI it wraps and indexes
  deep skill recipes (Markdown) the agent reads on demand. This module is the
  *discovery* half — plain HTML parsing (Floki), no kernel.

  Discovery is one query — every `<work-toolkit>` element under the root. A
  `<work-agent toolkits="…">` element lists the toolkits it may use; each name
  resolves to a `<work-toolkit id=…>`. No tool-search subsystem. The skill bodies
  are read lazily (the agent reads the `.md` file when a task routes to it); the
  runtime only resolves *which* toolkit, never inlines the manual.

  In the clean-room a toolkit's CLI is a WASM command (`run-command`,
  wb-11ck.21), not a native PATH binary — but the discovery contract is identical.

  ## TRUST BOUNDARY (wb-sec)

  The discovery root ($WB_TOOLKITS_ROOT or ./toolkits) is an UNAUTHENTICATED,
  writable directory. A toolkit dropped there is UNTRUSTED supply-chain input —
  NOT "first-party" by virtue of its location. Accordingly:

    * READ-ONLY surfaces (list / show / search) are open, but slugs/roots are
      path-contained (no `..`/separator traversal; files must resolve inside the
      toolkit) and $WB_TOOLKITS_ROOT is honored only if it is an existing dir.
    * EXECUTION surfaces (`verify` pre blocks, `run` task blocks) are DISABLED
      (wb-9ja). A :role bash block is arbitrary NATIVE bash; native execution is
      banned, so this lane never shells out — `exec_allowed?` is always false and
      `run_bash` is a no-op. Ship the toolkit's CLI as a WASM command instead.
    * BUILD (`build`) refuses to register a command under a reserved built-in
      name (jq/grep/upper); compilers run under the sandbox (see PackageManager).

  The intended sandboxed surface for a toolkit's CLI is the WASM `run-command`
  path (Dock-gated). Host bash from skill files bypasses that and is therefore
  gated/capped/isolated above. See docs/TOOLKITS-V3.org for the full model.
  """
  # The toolkit manifest is a single `<work-toolkit>` HTML element (work-* model;
  # org fully retired — see docs/WORK-FORMAT.md). Skills are Markdown recipes.
  @manifest "manifest.html"
  @skill_ext ".md"

  @doc """
  Every `<work-toolkit>` element in a workbook's HTML — the discovery query, now
  HTML-native (a `<work-toolkit>` element replaces the old `:toolkit:` org node).
  Returns the same view shape (`%{id, title, version, cli, status, skill_dir}`).
  """
  def discover(html) when is_binary(html) do
    html |> work_toolkit_nodes() |> Enum.map(&view/1)
  end

  @doc """
  Discover toolkits on disk: read every `<root>/<name>/manifest.html`, parse its
  `<work-toolkit>` element, and tag the view with its directory so the agent can
  read a skill on demand. A toolkit is a directory; discovery is plain HTML parsing.
  """
  def discover_dir(root) do
    Path.wildcard(Path.join(root, "*/#{@manifest}"))
    |> Enum.flat_map(fn manifest ->
      dir = Path.dirname(manifest)
      manifest |> File.read!() |> discover() |> Enum.map(&Map.put(&1, :dir, dir))
    end)
  end

  @doc "Skill names available in a toolkit dir (read the body on demand — progressive disclosure)."
  def skills(toolkit_dir) do
    Path.wildcard(Path.join([toolkit_dir, "skills", "*#{@skill_ext}"]))
    |> Enum.map(&Path.basename(&1, @skill_ext))
    |> Enum.sort()
  end

  @doc """
  Resolve an `:agent:` node's `:TOOLKITS:` list → the toolkit nodes it may use.
  Computes the **transitive closure** over toolkit→toolkit `:REQUIRES:` edges
  BEFORE flattening: subscribing to a toolkit that REQUIRES another pulls the
  dependency in once (dedup, declared-first order). A `:REQUIRES:` token is a
  graph edge only when it names a known toolkit id (optionally `id@semver`);
  native-CLI pre-flights (`git>=2.30`) are not edges. The DAG is cycle-checked —
  a back-edge raises. Unknown names are dropped (a missing toolkit is not a crash).

  Discovery/closure ONLY — caps stay grant-gated (a dep edge never widens powers).
  """
  def resolve(html, agent_id) when is_binary(html) do
    wanted = html |> agent_toolkits(agent_id)
    tks = work_toolkit_nodes(html)
    by_id = Map.new(tks, &{&1.attrs["id"], view(&1)})
    # Edges sourced from each `<work-toolkit requires="…">` attribute.
    edges = Map.new(tks, &{&1.attrs["id"], parse_requires(&1.attrs["requires"])})
    closure(wanted, edges, Map.keys(by_id))
    |> Enum.map(&by_id[&1])
    |> Enum.reject(&is_nil/1)
  end

  # The `toolkits` list declared on a `<work-agent id=…>` element, or [].
  defp agent_toolkits(html, agent_id) do
    case Floki.parse_fragment(html) do
      {:ok, tree} ->
        case Floki.find(tree, "work-agent[id=\"#{agent_id}\"]") do
          [node | _] -> Floki.attribute([node], "toolkits") |> List.first() |> to_string() |> String.split()
          [] -> []
        end

      {:error, _} ->
        []
    end
  end

  @doc """
  Transitive closure of `roots` over toolkit-id `:REQUIRES:` edges.

  `edges` maps a toolkit id → its parsed `#+REQUIRES` tokens (the `parse_requires`
  shape). `known` is the set of installed toolkit ids — a `{:dep, name, _}` token
  is followed ONLY when `name ∈ known` (otherwise it's a native-CLI pre-flight, not
  a graph edge). Returns ids in declared-first, dependency-after order, deduped.
  Cycle-detects: a back-edge (a node re-entered while still on the active path)
  raises `ArgumentError` — the dependency graph is a DAG.
  """
  def closure(roots, edges, known) do
    known = MapSet.new(known)

    {acc, _seen} =
      Enum.reduce(roots, {[], MapSet.new()}, fn id, {acc, seen} ->
        visit(id, edges, known, acc, seen, MapSet.new())
      end)

    Enum.reverse(acc)
  end

  # DFS post-order with an active-path set for cycle detection. `acc` accumulates
  # ids reversed (a dep is appended before its dependent, so reverse yields
  # declared-first/dep-after); `seen` dedups across the whole walk.
  defp visit(id, edges, known, acc, seen, path) do
    cond do
      MapSet.member?(path, id) ->
        raise ArgumentError, "toolkit dependency cycle through #{id} (the REQUIRES graph must be a DAG)"

      MapSet.member?(seen, id) ->
        {acc, seen}

      true ->
        dep_ids =
          for {:dep, name, _raw} <- Map.get(edges, id, []), MapSet.member?(known, name), do: name

        {acc, seen} =
          Enum.reduce(dep_ids, {acc, seen}, fn dep, {acc, seen} ->
            visit(dep, edges, known, acc, seen, MapSet.put(path, id))
          end)

        {[id | acc], MapSet.put(seen, id)}
    end
  end

  @doc """
  Expand a flat list of declared toolkit ids into the transitive closure over
  on-disk `#+REQUIRES` toolkit-id edges — the disk-backed counterpart of the
  in-org `closure/3`, used by `injection_text/2`. Reads each toolkit's manifest
  descriptor for its edges; unknown/uninstalled ids pass through unfollowed.
  """
  def closure_disk(ids, root \\ default_root()) do
    descs = discover_dir(root)
    known = Enum.map(descs, & &1.id)

    edges =
      Map.new(descs, fn t ->
        {t.id, parse_descriptor(File.read!(Path.join(t.dir, @manifest))).requires}
      end)

    closure(ids, edges, known)
  end

  @doc """
  Resolve a toolkit by id and run its wrapped CLI as a registered WASM command —
  the vertical from L4 discovery to the L0 command leaf. The toolkit's `CLI_BIN`
  is the command name (jq, ripgrep, ...); in the clean-room that CLI is a
  sandboxed WASM command, not a native PATH binary.
  """
  def run(org, toolkit_id, input) when is_binary(org) do
    case org |> discover() |> Enum.find(&(&1.id == toolkit_id)) do
      nil -> {:error, {:no_toolkit, toolkit_id}}
      %{cli: nil} -> {:error, {:no_cli, toolkit_id}}
      %{cli: cli} -> Workbooks.CommandRegistry.run(cli, input)
    end
  end

  # ── The `wb toolkit` surface (wb-4bj.2) ──────────────────────────────────
  # The CLI help-wrapper that teaches an agent the underlying CLI from our skill
  # files. Thin reads over the on-disk org toolkits + the :role block executor.
  # Discovery rides discover_dir/1; these add the human/agent-facing rendering.

  @doc """
  Default discovery root: $WB_TOOLKITS_ROOT (validated), else first of
  toolkits/ | ../toolkits that exists.

  SECURITY (wb-sec, finding #6): $WB_TOOLKITS_ROOT is honored ONLY if it names an
  existing directory. An unset/blank/non-dir value falls back to the in-tree
  defaults rather than letting a bogus value repoint the whole surface. Note the
  trust-boundary caveat in the moduledoc: the discovery root is read-only/search
  by default; EXECUTION (verify/run/build) is separately gated — see TOOLKITS-V3.
  """
  def default_root do
    env = System.get_env("WB_TOOLKITS_ROOT")

    cond do
      is_binary(env) and env != "" and File.dir?(env) -> env
      true -> Enum.find(["toolkits", "../toolkits", Path.expand("../toolkits", File.cwd!())], &File.dir?/1) || "toolkits"
    end
  end

  @doc "`wb toolkit list` — every toolkit under the root, keyed by id, with status + tagline."
  def list_text(root \\ default_root()) do
    case discover_dir(root) do
      [] ->
        "(no toolkits under #{root})"

      tks ->
        tks
        |> Enum.sort_by(& &1.id)
        |> Enum.map_join("\n", fn t ->
          "#{String.pad_trailing(t.id, 16)} #{String.pad_trailing(t.status || "-", 12)} #{manifest_kw(t.dir, "TAGLINE") || ""}"
        end)
    end
  end

  @doc """
  The compact TOOLKITS index injected into an org-defined agent's system prompt
  (V3 §P3) — progressive disclosure tier 1. One short entry per declared toolkit
  (tagline + skill slugs), plus the ONE query pattern for going deeper. Deliberately
  minimal: the index tells the agent WHAT exists and HOW to read more; the skill
  bodies stay on demand (`wb toolkit show <id> <skill>`), never in the prompt.

  The declared list is first expanded over the `#+REQUIRES` dependency graph
  (`closure_disk/2`) so a toolkit's required toolkits land in the index too —
  subscribe to A that REQUIRES B and B's entry/skills appear once.
  """
  def injection_text(names, root \\ default_root())

  def injection_text(names, root) do
    tks = discover_dir(root) |> Map.new(&{&1.id, &1})
    names = closure_disk(names, root)

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
            sk = skills(t.dir)
            {head, rest} = Enum.split(sk, 8)
            skill_line =
              cond do
                head == [] -> ""
                rest == [] -> "\n  skills: " <> Enum.join(head, ", ")
                true -> "\n  skills: " <> Enum.join(head, ", ") <> " (+#{length(rest)} more)"
              end

            "- #{id}: #{manifest_kw(t.dir, "TAGLINE") || "(no tagline)"}" <> skill_line
        end
      end)

    all = rows ++ Workbooks.Acp.injection_rows()

    if all == [] do
      ""
    else
      """
      ## Toolkits

      You have these toolkits. Before using one, read the relevant skill — call the
      `wb` tool: `toolkit show <id> <skill>` (or `toolkit search <query>` to find one).

      #{Enum.join(all, "\n")}
      """
      |> String.trim()
    end
  end

  # ── Discovered component catalog (P1, agent↔component contract) ───────────
  # When an agent's resolved toolkit closure includes a `#+EXEC: component`
  # toolkit (workponents/ctk), the chat can render the SDK's real `work-*`
  # custom elements inline. The catalog of which tags exist + their props is
  # NOT hardcoded — it is DISCOVERED from that toolkit's CEM (Custom Elements
  # Manifest, the `#+CEM` keyword → `custom-elements.json`). Mirrors the
  # `injection_text` Tier-1 pattern: a compact tag + prop-hint index, lazy on
  # bodies. The emit syntax (`#+begin_src component :type <tag>`) is unchanged;
  # only the CATALOG of valid `:type` values becomes dynamic.

  # `work-gen-block` (the chat's inline-card element) multiplexes on its `type`
  # attribute — the agent emits `:type <card>`; the chat forwards it to
  # <work-gen-block type=…>. These are the card kinds gen-block renders today
  # (an unknown type falls back to a labeled code block, so nothing vanishes).
  @gen_block_cards ~w(callout kv button link share)

  @doc """
  The component catalog injected into an agent's prompt when its resolved
  toolkit closure includes a `#+EXEC: component` toolkit. Returns "" when no
  such toolkit is in scope (or its CEM is missing/unreadable) — the agent then
  gets no component section and emits plain prose, exactly as before.

  Sourced from the component toolkit's CEM (`#+CEM` → `custom-elements.json`):
  one line per `work-*` tag (tag + attribute names), so the agent emits
  `#+begin_src component :type <tag>` for ANY discovered tag, not a hardcoded
  five.
  """
  def component_catalog(names, root \\ default_root())
  def component_catalog([], _root), do: ""

  def component_catalog(names, root) do
    names = closure_disk(names, root)

    tags =
      names
      |> Enum.flat_map(fn id ->
        case tk_dir(id, root) do
          nil -> []
          dir -> cem_tags(parse_descriptor(File.read!(Path.join(dir, @manifest))), dir, root)
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
      |> Enum.map(fn c -> "  :type #{c}" <> gen_block_hint(c) end)
      |> Enum.join("\n")

    # Every other discovered work-* tag (the standalone elements) + their props,
    # so the agent can reach any tag the SDK ships, not a hardcoded set.
    rest =
      tags
      |> Enum.map(& &1.tag)
      |> Enum.reject(&(&1 == "work-gen-block"))
      |> Enum.sort()

    rest_block =
      rest
      |> Enum.map(fn tag ->
        attrs = by_tag[tag].attrs
        hint = if attrs == [], do: "", else: " — props: " <> Enum.join(Enum.take(attrs, 8), ", ")
        "  #{tag}#{hint}"
      end)
      |> Enum.join("\n")

    cards_section =
      if card_block == "",
        do: "",
        else: "Inline cards (`:type` selects the card):\n#{card_block}\n\n"

    rest_section =
      if rest_block == "",
        do: "",
        else: "Other `work-*` elements (use the tag as `:type`):\n#{rest_block}\n"

    """
    ## Components

    You have a component toolkit. The chat renders the SDK's real `work-*`
    custom elements inline. To emit one, begin your message with `#+RENDER: org`
    on its own first line, then write:

      #+begin_src component :type <type> :<attr> <value> …
      body text (or `key: value` lines)
      #+end_src

    The `:key value` header args map to the element's attributes; the block body
    becomes its content. Reach for a component when a structured/visual answer
    earns it (you confirmed an action, surfaced data, offered a next step);
    otherwise reply in plain prose (it streams).

    DATA BINDING: data elements (chart, table, spark) take their data inline via
    `:rows` — a JSON array of row OBJECTS, e.g.
    `:rows [{"region":"NA","revenue":1200},{"region":"EU","revenue":980}]` — or
    `:csv` (CSV text with a header row). For a chart, `:x`/`:y` name the columns and
    `:type` is the shape (bar/line/area); a scalar uses `:value`/`:label`/`:delta`.
    Use `:src-name`/`:query` ONLY when a named data source already exists; otherwise
    put the data inline with `:rows` or `:csv`.

    #{cards_section}#{rest_section}
    """
    |> String.trim()
  end

  defp gen_block_hint("callout"), do: " — info/warn/ok/error banner (:tone, :title)"
  defp gen_block_hint("kv"), do: " — key/value table (:title; body = `key: value` lines)"
  defp gen_block_hint("button"), do: " — action button (:label, :action; fires work-intent)"
  defp gen_block_hint("link"), do: " — themed external link (:label, :href)"
  defp gen_block_hint("share"), do: " — member chips + invite (:title; body = target/members/role)"
  defp gen_block_hint(_), do: ""

  @doc "`wb toolkit show <id>` — the manifest front door + the skill index."
  def show_text(id, root \\ default_root()) do
    case tk_dir(id, root) do
      nil ->
        "no such toolkit: #{id}"

      dir ->
        File.read!(Path.join(dir, @manifest)) <>
          "\n\nSkills (read with `wb toolkit show #{id} <skill>`):\n" <>
          Enum.map_join(skills(dir), "\n", &("  " <> &1))
    end
  end

  @doc "`wb toolkit show <id> <skill>` — a skill body, with a #+CAPTION TOC header."
  def show_skill_text(id, slug, root \\ default_root()) do
    with dir when not is_nil(dir) <- tk_dir(id, root),
         path when not is_nil(path) <- skill_path(dir, slug) do
      body = File.read!(path)
      toc = captions(body)
      head = if toc == [], do: "", else: "TOC (CAPTIONs):\n" <> Enum.map_join(toc, "\n", &("  • " <> &1)) <> "\n\n"
      head <> body
    else
      _ -> "no such skill: #{id}/#{slug}"
    end
  end

  @doc "`wb toolkit search <q>` — substring match across all skills (path:line: text)."
  def search_text(query, root \\ default_root()) do
    q = String.downcase(query)

    base = Path.expand(root)

    hits =
      Path.wildcard(Path.join(root, "*/skills/**/*#{@skill_ext}"))
      # SECURITY (wb-sec, finding #6): only emit content for files that truly live
      # under the resolved root — a symlinked entry that escapes is skipped.
      |> Enum.filter(&contained?(&1, base))
      |> Enum.flat_map(fn path ->
        rel = Path.relative_to(path, root)

        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _} -> String.contains?(String.downcase(line), q) end)
        |> Enum.map(fn {line, n} -> "#{rel}:#{n}: #{String.trim(line)}" end)
      end)

    if hits == [], do: "(no matches for #{inspect(query)})", else: Enum.join(hits, "\n")
  end

  @doc "`wb toolkit verify <id>` — structural checks + run every :role pre block in the toolkit's skills."
  def verify_text(id, root \\ default_root()) do
    case tk_dir(id, root) do
      nil ->
        "no such toolkit: #{id}"

      dir ->
        d = parse_descriptor(File.read!(Path.join(dir, @manifest)))

        struct =
          [
            {File.exists?(Path.join(dir, @manifest)), "#{@manifest} present"},
            {File.exists?(Path.join([dir, "skills", "overview#{@skill_ext}"])), "skills/overview#{@skill_ext} present"}
          ] ++ exec_checks(d) ++ cap_checks(d) ++ trust_checks(dir, d)

        # :role pre blocks are arbitrary NATIVE bash. Native execution is banned
        # (wb-9ja), so verify never runs them — the structural checks above are the
        # gate; any pre blocks are reported as disabled (not skipped-pending-flag).
        n = pre_block_count(dir)
        pre = if n == 0, do: [], else: [{true, "pre checks DISABLED (#{n} block(s); native :role bash execution removed — wb-9ja)"}]

        Enum.map_join(struct ++ pre, "\n", fn {ok, label} -> "#{if ok, do: "✓", else: "✗"} #{label}" end)
    end
  end

  @doc """
  `wb toolkit eval <id>` — run the toolkit's bundled eval suite (Tier 1,
  deterministic): each `evals/*.org` case's `:role eval` block runs under the
  same sandbox as verify (only with WB_TOOLKIT_EXEC=1), and PASSES on exit 0 +
  stdout containing the case's `#+EXPECT:` substring (when set). See EVALS.org.
  """
  def eval_text(id, root \\ default_root(), filter \\ nil, model \\ nil) do
    case tk_dir(id, root) do
      nil ->
        "no such toolkit: #{id}"

      dir ->
        cases =
          Path.wildcard(Path.join([dir, "evals", "*.org"]))
          |> Enum.filter(&contained?(&1, Path.expand(dir)))
          # `filter` (a substring of the eval filename) runs just ONE case — cheap
          # iteration on a single eval rather than the whole LLM-driven suite.
          |> Enum.filter(&(is_nil(filter) or String.contains?(Path.basename(&1), filter)))
          |> Enum.sort()

        if cases == [] do
          if filter,
            do: "#{id}: no eval matches #{inspect(filter)}",
            else: "#{id}: no eval suite (add evals/*.org — see toolkits/EVALS.org)"
        else
          results = Enum.map(cases, &run_eval_case(&1, dir, id, model))
          pass = Enum.count(results, &(elem(&1, 0) == :pass))
          skip = Enum.count(results, &(elem(&1, 0) == :skip))
          n = length(results)
          skipnote = if skip > 0, do: " (#{skip} skipped)", else: ""

          "#{id} evals: #{pass}/#{n - skip} passed#{skipnote}\n" <>
            Enum.map_join(results, "\n", fn {st, label} ->
              "  #{%{pass: "✓", fail: "✗", skip: "·"}[st]} #{label}"
            end)
        end
    end
  end

  # Each evals/*.org is one case: Tier 2 (agent + judge) if it declares :TASK:,
  # else Tier 1 (deterministic :role eval + #+EXPECT:). Returns {:pass|:fail|:skip, label}.
  defp run_eval_case(path, dir, id, model \\ nil) do
    text = File.read!(path)
    name = Path.relative_to(path, dir)

    cond do
      prop(text, "TASK") != nil -> agent_judge_case(text, name, dir, id, model)
      extract_role_blocks(text, "eval") != [] -> deterministic_case(text, name, dir)
      true -> {:fail, "#{name}: no :role eval block and no :TASK:"}
    end
  end

  # Tier 1 — deterministic :role eval blocks ran NATIVE bash. Native execution is
  # banned (wb-9ja), so this tier can no longer run; report it disabled. (Tier 2,
  # the agent+judge case below, still works — it runs the in-WASM agent, no native.)
  defp deterministic_case(_text, name, _toolkit_dir) do
    {:skip, "#{name}: DISABLED (native :role bash eval removed — wb-9ja)"}
  end

  # Tier 2 — run an agent on :TASK: (the toolkit's overview injected so it knows
  # the surface), then a judge model scores the result + tool trace vs :RUBRIC:.
  defp agent_judge_case(text, name, dir, id, model \\ nil) do
    task = prop(text, "TASK")
    rubric = prop(text, "RUBRIC") || "The result correctly and completely satisfies the task."
    exec? = prop(text, "EXEC") in ["true", "yes", "1"]
    # MAX_STEPS is a high SAFETY-NET (runaway guard), NOT a binding cap. Evals must
    # let the agent WORK THE PROBLEM to completion and MEASURE how it solved it (the
    # step/tool trace is telemetry, observed by the judge) — a low cap cuts the agent
    # off mid-task and SKEWS the result. So an eval rarely sets MAX_STEPS; the default
    # matches the agent's normal operating budget (40). Size a per-eval cap only as a
    # generous safety-net, never to gate pass/fail. (User direction; [[no-max-turns]].)
    max = case Integer.parse(prop(text, "MAX_STEPS") || "40") do
            {n, _} -> n
            _ -> 40
          end

    cond do
      not llm_key?() ->
        {:skip, "#{name}: SKIPPED (no LLM key — set OPENROUTER_API_KEY)"}

      true ->
        overview =
          case File.read(Path.join([dir, "skills", "overview#{@skill_ext}"])) do
            {:ok, o} -> "\n\n#{id} toolkit overview:\n" <> o
            _ -> ""
          end

        system =
          (prop(text, "SYSTEM") ||
             "You are an agent being evaluated. Use the #{id} toolkit to complete the task; state your final result clearly.") <>
            overview

        run =
          Workbooks.Agent.run(system, task,
            model: model || System.get_env("WB_EVAL_MODEL"),
            max_steps: max,
            exec: exec?,
            tenant: "eval"
          )

        # Telemetry from the run's tool trace (the universal step record): step
        # count, tools used, and errors — the judge factors execution, not just text.
        # `steps` = LLM TURNS; `commands` = actual tool CALLS (one per event). An
        # agent can run several commands in a single turn (batched/parallel tool
        # calls), so a rubric that wants "ran >= 2 commands" must read `commands`,
        # NOT `steps` — else a batching agent shows steps:1 and is wrongly failed.
        tel = %{
          steps: run.steps,
          commands: length(run.events),
          tools: run.events |> Enum.map(& &1.tool) |> Enum.uniq(),
          errors: Enum.count(run.events, &(&1[:error] || (&1[:exit_code] && &1[:exit_code] != 0)))
        }

        {verdict, reason} = judge(task, rubric, run.result, tel)
        {verdict, "#{name} [steps:#{tel.steps} cmds:#{tel.commands} tools:#{Enum.join(tel.tools, ",")} errs:#{tel.errors}] — #{reason}"}
    end
  end

  defp judge(task, rubric, result, tel) do
    sys =
      "You are a strict evaluator. Given a TASK, a RUBRIC, and an agent's RESULT, decide if the result satisfies the rubric. Respond with a verdict whose FIRST line is exactly PASS or FAIL, then one short line of reasoning."

    user = """
    TASK:
    #{task}

    RUBRIC:
    #{rubric}

    AGENT TELEMETRY: commands_run=#{tel.commands}, turns=#{tel.steps}, tools=[#{Enum.join(tel.tools, ", ")}], errors=#{tel.errors}
    (NOTE: commands_run = actual tool calls; turns = LLM round-trips. An agent may run several commands in one turn. When a rubric says "ran N commands / steps>=N", judge by commands_run, NOT turns.)

    AGENT RESULT:
    #{String.slice(result || "(no result)", 0, 4000)}
    """

    case Workbooks.Llm.complete([%{role: "system", content: sys}, %{role: "user", content: user}], []) do
      {:ok, %{content: content}} when is_binary(content) ->
        first = content |> String.split("\n", trim: true) |> List.first() |> to_string() |> String.trim()
        verdict = if first |> String.upcase() |> String.starts_with?("PASS"), do: :pass, else: :fail
        {verdict, String.trim(String.slice(content, 0, 200))}

      other ->
        {:fail, "judge error: #{inspect(other)}"}
    end
  end

  # Read a `:KEY: value` property line (PROPERTIES drawer); nil if absent.
  defp prop(text, key) do
    case Regex.run(~r/^\s*:#{key}:\s*(.+?)\s*$/m, text) do
      [_, v] -> String.trim(v)
      _ -> nil
    end
  end

  defp llm_key?,
    do:
      Workbooks.Secrets.get("OPENROUTER_API_KEY") not in [nil, ""] or
        System.get_env("WB_LLM_KEY") not in [nil, ""]

  # ── Third-party trust: manifest provenance (AUTHOR_DID + SIGNATURE) ────────
  # A `#+TRUST: third-party` toolkit must carry a did:key signature over its
  # manifest (Ed25519 over the manifest body with SIGNATURE lines removed,
  # trimmed — same crypto as Workbooks.Manifest/Git, no new scheme). The dir is
  # supply-chain input (see the threat model above): the signature binds the
  # manifest's declared contract (EXEC/CAPS/BUILD_SRC) to an author identity, so
  # tampering with a vetted third-party toolkit is detectable. First-party
  # toolkits skip this (location-trust is fine for our own repo).

  @doc "Sign a toolkit's manifest as `tenant`: writes #+AUTHOR_DID + #+SIGNATURE."
  def sign_text(id, tenant, root \\ default_root()) do
    case tk_dir(id, root) do
      nil ->
        "no such toolkit: #{id}"

      dir ->
        path = Path.join(dir, @manifest)
        did = Workbooks.Git.did(tenant)

        body =
          File.read!(path)
          |> strip_manifest_lines(["SIGNATURE", "AUTHOR_DID"])
          |> Kernel.<>("\n#+AUTHOR_DID: #{did}")
          |> String.trim()

        sig = Workbooks.Git.sign(tenant, body) |> Base.encode64()
        File.write!(path, body <> "\n#+SIGNATURE: #{sig}\n")
        "signed #{id} as #{did}"
    end
  end

  @doc "Verify a manifest's provenance: {:ok, did} | {:error, reason}."
  def manifest_provenance(dir) do
    body = File.read!(Path.join(dir, @manifest))
    d = parse_descriptor(body)

    cond do
      is_nil(d.author_did) -> {:error, :no_author_did}
      is_nil(d.signature) -> {:error, :no_signature}
      true ->
        canonical = body |> strip_manifest_lines(["SIGNATURE"]) |> String.trim()

        case Base.decode64(d.signature) do
          {:ok, sig} ->
            if Workbooks.Git.verify_sig(d.author_did, canonical, sig),
              do: {:ok, d.author_did},
              else: {:error, :bad_signature}

          :error ->
            {:error, :bad_signature_encoding}
        end
    end
  end

  defp strip_manifest_lines(body, keys) do
    re = ~r/^[ \t]*#\+(?:#{Enum.join(keys, "|")}):.*\n?/m
    Regex.replace(re, body, "")
  end

  defp trust_checks(dir, %{trust: "third-party"}) do
    case manifest_provenance(dir) do
      {:ok, did} -> [{true, "third-party signature valid (#{did})"}]
      {:error, why} -> [{false, "third-party provenance: #{why} (sign with `wb toolkit sign <id>`)"}]
    end
  end

  defp trust_checks(_dir, _first_party), do: []

  # ── Build descriptor (P4, wb-tk3) ─────────────────────────────────────────
  # The declarative auto-wrap: a few manifest keywords tell the runtime HOW the
  # toolkit's CLI runs and HOW to build it. Zero glue per toolkit.
  #   #+EXEC:       command | posix | task | federation
  #   #+BUILD_SRC:  crate:<name> | git+<url> | path:<dir>
  #   #+BUILD_LANG: rust | go | js | py
  #   #+CAPS:       <space-separated dock caps>
  # CLI_BIN (the command name to register under) is read from the manifest's
  # :PROPERTIES: drawer (CLI_BIN) or the #+CLI_BIN keyword, same as discovery.

  @doc """
  Parse a toolkit's build descriptor from its `manifest.html`. Returns a map with
  `:exec`, `:build_src` (a `{:crate|:git|:path, value}` tuple or nil), `:build_lang`,
  `:caps` (list), `:cli_bin`, and `:arg_mode`. Missing keys are nil/[]. The
  descriptor is what `wb toolkit build`/`verify` act on.
  """
  def descriptor(id, root \\ default_root()) do
    case tk_dir(id, root) do
      nil -> {:error, {:no_toolkit, id}}
      dir -> {:ok, parse_descriptor(File.read!(Path.join(dir, @manifest)))}
    end
  end

  @doc false
  # Parse a manifest body (`<work-toolkit>` HTML) into the build descriptor. Each
  # field reads the same-named attribute (`build-src` etc. dash-cased per HTML).
  def parse_descriptor(body) do
    a = case work_toolkit(body) do
          %{attrs: attrs} -> attrs
          nil -> %{}
        end

    %{
      exec: blank_to_nil(a["exec"]),
      trust: blank_to_nil(a["trust"]) || "first-party",
      build_src: parse_build_src(blank_to_nil(a["build-src"])),
      build_lang: blank_to_nil(a["build-lang"]),
      caps: (a["caps"] || "") |> String.split(),
      cli_bin: blank_to_nil(a["cli"]),
      arg_mode: arg_mode(a["arg-mode"]),
      sha256: blank_to_nil(a["sha256"]),
      wasm_path: blank_to_nil(a["wasm-path"]),
      preopen: blank_to_nil(a["preopen"]),
      author_did: blank_to_nil(a["author-did"]),
      signature: blank_to_nil(a["signature"]),
      cem: blank_to_nil(a["cem"]),
      requires: parse_requires(a["requires"])
    }
  end

  # `#+REQUIRES` is a mixed list: some entries are toolkit→toolkit dependency
  # edges, others are native-CLI pre-flights the skills assume. Parse the raw
  # line into typed tokens WITHOUT yet knowing the toolkit id set — classification
  # against known ids happens in closure/2. Two syntaxes disambiguate intent:
  #
  #   * `git>=2.30`, `node>=20`, `cargo`, `xcode`, `wb` → :cli pre-flight. A token
  #     carrying a version OPERATOR (>= > <= < = ~ ^) is always a native CLI (the
  #     existing TOOLKIT-MANIFEST prose form — keeps the shipped manifests as
  #     pre-flights, zero graph edges).
  #   * `glyphs`, `icons@0.2.0` → :dep candidate (bare id, optionally npm-style
  #     `@semver`). Becomes a real edge only if the bare name matches a known
  #     `:toolkit:` id; otherwise it falls back to a :cli pre-flight in closure/2.
  #
  # Parenthetical prose (e.g. "(to deploy the gateway)") is stripped as comment.
  @doc """
  Parse a raw `requires` value into typed `{:cli, tok} | {:dep, name, raw}` tokens
  (nil → []). Reads a `<work-toolkit requires="…">` attribute into the edge shape
  `closure/3` consumes.
  """
  def parse_requires(nil), do: []

  def parse_requires(line) do
    line
    |> String.replace(~r/\([^)]*\)/, " ")
    |> String.split([",", " "], trim: true)
    |> Enum.map(&classify_requirement/1)
  end

  @req_op ~r/(>=|<=|>|<|=|~|\^)/

  defp classify_requirement(tok) do
    cond do
      Regex.match?(@req_op, tok) ->
        {:cli, tok}

      String.contains?(tok, "@") ->
        [name | _] = String.split(tok, "@", parts: 2)
        {:dep, name, tok}

      true ->
        {:dep, tok, tok}
    end
  end

  # crate:<name> | git+<url> | path:<dir> | wasm:<url> | archive:<url> → tagged tuple.
  defp parse_build_src(nil), do: nil

  defp parse_build_src(spec) do
    spec = String.trim(spec)

    cond do
      String.starts_with?(spec, "crate:") -> {:crate, String.trim_leading(spec, "crate:")}
      String.starts_with?(spec, "git+") -> {:git, String.trim_leading(spec, "git+")}
      String.starts_with?(spec, "path:") -> {:path, String.trim_leading(spec, "path:")}
      String.starts_with?(spec, "wasm:") -> {:wasm, String.trim_leading(spec, "wasm:")}
      String.starts_with?(spec, "archive:") -> {:archive, String.trim_leading(spec, "archive:")}
      String.starts_with?(spec, "gobuild:") -> {:gobuild, String.trim_leading(spec, "gobuild:")}
      String.starts_with?(spec, "script:") -> {:script, String.trim_leading(spec, "script:")}
      String.starts_with?(spec, "zigbuild:") -> {:zigbuild, String.trim_leading(spec, "zigbuild:")}
      true -> {:unknown, spec}
    end
  end

  defp arg_mode("stdin1"), do: :stdin1
  defp arg_mode("argv"), do: :argv
  defp arg_mode(_), do: :argv

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s), do: s

  @doc """
  `wb toolkit build <id>` — the declarative auto-wrap. Read the toolkit's build
  descriptor and materialize its CLI as a runnable command:
    - #+EXEC: command + #+BUILD_SRC crate:<name> → CommandRegistry.build_and_register_crate
    - #+EXEC: command + #+BUILD_SRC path:<dir>   → PackageManager.build_dir + register
  Other EXEC modes (posix/task/federation) need no WASM build. Returns a human/agent
  string describing what happened (real build output on failure).
  """
  def build_text(id, root \\ default_root()), do: build_text(id, nil, root)

  @doc """
  Build a toolkit. A toolkit may hold a SET of build entries in `runtimes/*.org`
  (e.g. the `palette` toolkit = many language runtimes, one cohesive set) — then
  `wb toolkit build <id>` builds them all and `wb toolkit build <id> <name>` builds
  one. A plain single-CLI toolkit (no runtimes/) builds from its own manifest.
  """
  def build_text(id, which, root) do
    case tk_dir(id, root) do
      nil ->
        "no such toolkit: #{id}"

      dir ->
        entries = runtime_entries(dir)
        d = parse_descriptor(File.read!(Path.join(dir, @manifest)))

        cond do
          # Supply-chain gate: an unsigned/tampered third-party toolkit never builds.
          d.trust == "third-party" and not match?({:ok, _}, manifest_provenance(dir)) ->
            {:error, why} = manifest_provenance(dir)
            "#{id}: REFUSED — third-party toolkit with invalid provenance (#{why}); author must `wb toolkit sign #{id}`"

          entries == [] ->
            do_build(id, d)

          which not in [nil, ""] ->
            case Enum.find(entries, fn {n, _} -> n == which end) do
              nil ->
                have = entries |> Enum.map(&elem(&1, 0)) |> Enum.sort() |> Enum.join(", ")
                "no such runtime: #{id}/#{which} (have: #{have})"

              {n, f} ->
                do_build("#{id}/#{n}", desc_with_dir(f))
            end

          true ->
            entries
            |> Enum.sort()
            |> Enum.map_join("\n", fn {n, f} -> do_build("#{id}/#{n}", desc_with_dir(f)) end)
        end
    end
  end

  @doc """
  Inline self-authoring (wb-rhs.4): build a command directly from a SOURCE FILE an
  agent just wrote — no manifest ceremony. `wb toolkit build-inline <name> <lang>
  <file>`. The agent writes the file in its workdir, then registers it as a
  runnable command in one step: write → build-in-sandbox → content-address →
  register. The built command is capped by the Instance's Policy profile like any
  other command — self-authoring never widens the granted capability set.
  """
  def build_inline_text(name, lang, file) do
    if File.regular?(file) do
      case Workbooks.CommandRegistry.build_and_register_inline(name, lang, File.read!(file)) do
        {:ok, path} ->
          "built + registered command `#{name}` (#{lang}) → #{path}\nrun it via the Dock: run-command #{name}"

        {:error, reason} ->
          "build-inline failed for `#{name}` (#{lang}): #{inspect(reason)}"
      end
    else
      "no such source file: #{file}"
    end
  end

  @doc """
  PROMOTE a session command to a durable workspace toolkit (wb-rhs.6 — the
  lifecycle ladder: session → workspace → registry). Takes the source an agent
  authored inline (which is ephemeral: built into :persistent_term, gone when the
  Instance dies) and materializes a real, source-owned toolkit dir under the
  toolkits root: manifest.org (#+EXEC: command, #+TRUST: first-party) + the source
  in the per-language layout build_dir expects + a skill stub. The result is a
  normal toolkit — `wb toolkit build` rebuilds it deterministically, it's
  discoverable by `(tags :toolkit:)`, and it packs into a workbook for the
  registry (Library.store) and install elsewhere (Library.install).

  This is the "Org owns the spec, WASM owns the artifact" rung: promotion persists
  the SOURCE (rebuildable), not just the compiled bytes. Trust stays first-party
  (yours); a third-party consumer grants its #+CAPS on install.
  """
  def promote_text(name, lang, src_file, opts \\ []) do
    root = opts[:root] || default_root()
    tagline = opts[:tagline] || "Promoted session command."

    cond do
      name in Workbooks.CommandRegistry.reserved_names() ->
        "cannot promote: #{inspect(name)} is a reserved built-in command name"

      not Regex.match?(~r/^[A-Za-z0-9_.-]+$/, name) ->
        "cannot promote: invalid toolkit/command name #{inspect(name)}"

      lang not in ~w(rust c zig js ts go) ->
        "cannot promote: unsupported language #{inspect(lang)}"

      not File.regular?(src_file) ->
        "cannot promote: no such source file #{inspect(src_file)}"

      true ->
        {build_src, entry_rel, extra} = lang_layout(lang, name)
        dir = Path.join(root, name)
        source = File.read!(src_file)

        File.mkdir_p!(Path.dirname(Path.join(dir, entry_rel)))
        File.write!(Path.join(dir, entry_rel), source)
        for {rel, bytes} <- extra do
          File.mkdir_p!(Path.dirname(Path.join(dir, rel)))
          File.write!(Path.join(dir, rel), bytes)
        end

        File.mkdir_p!(Path.join(dir, "skills"))
        File.write!(Path.join(dir, "skills/overview#{@skill_ext}"), promote_skill(name))
        File.write!(Path.join(dir, @manifest), promote_manifest(name, lang, build_src, tagline))

        "promoted session command → workspace toolkit `#{name}` at #{dir}\n" <>
          "  build it: wb toolkit build #{name}\n" <>
          "  then it packs into a workbook (Library.store) and installs elsewhere (Library.install)"
    end
  end

  # Per-language source layout build_dir/2 expects, expressed relative to the
  # toolkit dir. The #+BUILD_SRC path is resolved against the toolkit dir by
  # do_build_clause, then build_dir/2 looks for the lang's entry under it.
  #   rust: build_dir(<tk>) wants <tk>/src/main.rs (+ Cargo.toml) → BUILD_SRC path:.
  #   js/ts/zig/go/c: build_dir(<tk>/src) wants the entry directly in src/.
  defp lang_layout("rust", name),
    do: {".", "src/main.rs", %{"Cargo.toml" => ~s|[package]\nname = "#{name}"\nversion = "0.1.0"\nedition = "2021"\n|}}

  defp lang_layout("js", _name), do: {"src", "src/index.js", %{}}
  defp lang_layout("ts", _name), do: {"src", "src/index.ts", %{}}
  defp lang_layout("zig", _name), do: {"src", "src/main.zig", %{}}
  defp lang_layout("go", _name), do: {"src", "src/main.go", %{}}
  defp lang_layout("c", _name), do: {"src", "src/main.c", %{}}

  defp promote_manifest(name, lang, build_src, tagline) do
    """
    <work-toolkit
      id="#{name}"
      cli="#{name}"
      version="0.1.0"
      status="experimental"
      tagline="#{tagline}"
      exec="command"
      trust="first-party"
      build-lang="#{lang}"
      build-src="path:#{build_src}"
      arg-mode="argv">
      <work-doc title="#{name} toolkit">
        Promoted from a session command (wb-rhs.6). Source-owned + rebuildable.

        | need   | skill    |
        |--------|----------|
        | use it | overview |
      </work-doc>
    </work-toolkit>
    """
  end

  defp promote_skill(name) do
    """
    # #{name} — overview

    ## When to use this
    A command promoted from a session. NOT for anything else yet — extend the
    skill as the toolkit grows.

    ## Workflow
    Run it through the Dock: `run-command #{name}` (argv + stdin → stdout).

    ## Verification checklist
    - [ ] `wb toolkit build #{name}` registers the command
    - [ ] `run-command #{name}` produces expected output
    """
  end

  # A runtime entry is either runtimes/<name>.org (a flat pinned spec) or
  # runtimes/<name>/manifest.org (a dir carrying a build script + assets).
  defp runtime_entries(dir) do
    flat =
      Path.wildcard(Path.join([dir, "runtimes", "*.org"]))
      |> Enum.map(fn f -> {Path.basename(f, ".org"), f} end)

    sub =
      Path.wildcard(Path.join([dir, "runtimes", "*", "manifest.html"]))
      |> Enum.map(fn f -> {Path.basename(Path.dirname(f)), f} end)

    flat ++ sub
  end

  defp desc_with_dir(file),
    do: parse_descriptor(File.read!(file)) |> Map.put(:src_dir, Path.dirname(file))

  defp do_build(id, %{cli_bin: nil}),
    do: "cannot build #{id}: no CLI_BIN declared (nothing to register a command under)"

  # SECURITY (wb-sec, finding #12): a toolkit's CLI_BIN is attacker-controlled
  # DATA. Refuse to build/register a command under a RESERVED built-in name
  # (jq/grep/upper) when this descriptor would register a command (crate/path) —
  # otherwise importing an untrusted toolkit silently hijacks a core command for
  # every Instance. (CommandRegistry also enforces this; this is the clear, early
  # surface, before any compile runs.) Non-registering modes fall through.
  defp do_build(id, %{cli_bin: bin, exec: exec, build_src: {kind, _}} = d)
       when is_binary(bin) and exec in ["command", nil] and kind in [:crate, :path, :wasm, :archive, :gobuild, :script, :zigbuild] do
    if bin in Workbooks.CommandRegistry.reserved_names() do
      "cannot build #{id}: CLI_BIN #{inspect(bin)} is a reserved built-in command name (refusing to shadow it)"
    else
      # Record the toolkit's #+TRUST so its command runs at the right isolation tier
      # (third-party → :node). Set before build; harmless if the build then fails.
      Workbooks.CommandRegistry.set_trust(bin, d[:trust] || "first-party")
      do_build_clause(id, d)
    end
  end

  defp do_build(id, d), do: do_build_clause(id, d)

  defp do_build_clause(id, %{exec: exec}) when exec in ["task", "federation"],
    do: "#{id}: #+EXEC: #{exec} — no command to build (task/federation toolkits ship no CLI binary)"

  defp do_build_clause(id, %{exec: "posix", cli_bin: bin}) do
    case System.find_executable(bin) do
      nil -> "#{id}: #+EXEC: posix — native binary #{inspect(bin)} not found on PATH (install it; nothing to build)"
      path -> "#{id}: #+EXEC: posix — native binary #{bin} present at #{path} (no WASM build needed)"
    end
  end

  # crate:<name> — NATIVE cargo build of an upstream binary crate REMOVED (wb-9ja).
  # Build inline/dir Rust SOURCE in-sandbox instead (path:<dir> → the rust lane).
  defp do_build_clause(id, %{exec: exec, build_src: {:crate, crate}})
       when exec in ["command", nil],
       do: "#{id}: native cargo build of crate #{crate} removed (wb-9ja) — fetching+building an upstream binary crate natively is banned; vendor the source and use path:<dir> (in-sandbox rust lane)"

  defp do_build_clause(id, %{exec: exec, build_src: {:path, dir}, build_lang: lang, cli_bin: bin, arg_mode: mode})
       when exec in ["command", nil] do
    lang = lang || "rust"
    abs = if Path.type(dir) == :absolute, do: dir, else: Path.join(tk_dir(id, default_root()) || ".", dir)

    case Workbooks.PackageManager.build_dir(abs, lang) do
      {:ok, wasm, _} ->
        case Workbooks.CommandRegistry.register_artifact(bin, wasm, mode) do
          {:ok, addressed} ->
            "#{id}: built #{lang} dir #{abs} → #{addressed}; registered command #{inspect(bin)} (mode #{mode})"

          {:error, reason} ->
            "#{id}: built #{lang} dir #{abs} but FAILED to content-address:\n" <> error_text(reason)
        end

      {:error, reason} ->
        "#{id}: build FAILED for path #{abs} (#{lang}):\n" <> error_text(reason)
    end
  end

  # #+EXEC: kernel — a bytes→bytes reactor (wb-pkh.11), NOT a stdio command. Build
  # the C source via the source→kernel recipe (Compilers.c_compile_to_kernel) and
  # register it in KernelRegistry (opened by Workbooks.Kernel / Fabric.map_kernel,
  # never run-command). cli_bin names the kernel.
  defp do_build_clause(id, %{exec: "kernel", build_src: {:path, dir}, build_lang: lang, cli_bin: bin})
       when lang in ["c", nil] do
    abs = if Path.type(dir) == :absolute, do: dir, else: Path.join(tk_dir(id, default_root()) || ".", dir)

    case Path.wildcard(Path.join(abs, "**/*.c")) do
      [] ->
        "#{id}: kernel build — no .c source in #{abs}"

      [entry | _] ->
        case Workbooks.Compilers.c_compile_to_kernel(entry) do
          {:ok, wasm, _} ->
            case Workbooks.KernelRegistry.register(bin, wasm) do
              {:ok, addressed} -> "#{id}: built C kernel #{entry} → #{addressed}; registered kernel #{inspect(bin)}"
              {:error, reason} -> "#{id}: kernel built but register FAILED:\n" <> error_text(reason)
            end

          {:error, reason} ->
            "#{id}: kernel build FAILED for #{entry}:\n" <> error_text(reason)
        end
    end
  end

  defp do_build_clause(id, %{exec: "kernel", build_lang: lang}),
    do: "#{id}: #+EXEC: kernel — only #+BUILD_LANG: c is supported today (got #{inspect(lang)}); needs #+BUILD_SRC: path:<dir> with a .c source"

  # wasm:<url> — a PREBUILT runtime/compiler (qjs, python, …): fetch the pinned
  # URL, sha-verify, content-address, register. No build step runs (a prebuilt is
  # inert until run in the sandbox); the sha pin is the supply-chain gate.
  defp do_build_clause(id, %{exec: exec, build_src: {:wasm, url}, cli_bin: bin, arg_mode: mode, sha256: sha})
       when exec in ["command", nil] do
    case Workbooks.CommandRegistry.fetch_and_register_wasm(bin, url, sha, mode) do
      {:ok, addressed, hash} ->
        pin = if sha in [nil, ""], do: "  (UNPINNED — add `#+SHA256: #{hash}` to the manifest)", else: ""
        "#{id}: fetched prebuilt #{url} → #{addressed}; registered command #{inspect(bin)} (mode #{mode})#{pin}"

      {:error, reason} ->
        "#{id}: fetch FAILED for #{url}:\n" <> error_text(reason)
    end
  end

  # archive:<url> — a PREBUILT runtime that ships as a tar.gz (wasm + stdlib):
  # fetch + sha-verify + unpack + register the inner #+WASM_PATH with a default
  # #+PREOPEN so it finds its resources. The user's script is reached via an extra
  # preopen at run time (merged ahead by the registry).
  defp do_build_clause(id, %{exec: exec, build_src: {:archive, url}, cli_bin: bin, arg_mode: mode, sha256: sha, wasm_path: wp, preopen: pre})
       when exec in ["command", nil] do
    case Workbooks.CommandRegistry.fetch_and_register_archive(bin, url, sha, wp, pre, mode) do
      {:ok, addressed, hash} ->
        pin = if sha in [nil, ""], do: "  (UNPINNED — add `#+SHA256: #{hash}` to the manifest)", else: ""
        "#{id}: fetched + unpacked #{url} → #{addressed}; registered command #{inspect(bin)} (mode #{mode}, preopen #{pre || ".::/"})#{pin}"

      {:error, reason} ->
        "#{id}: fetch/unpack FAILED for #{url}:\n" <> error_text(reason)
    end
  end

  # gobuild / zigbuild / script — NATIVE build lanes REMOVED (wb-9ja). These drove
  # the native go/zig toolchains or a native bash build script to produce a wasm.
  # Native execution is banned; CommandRegistry now returns lane-unavailable for
  # them, so the toolkit build surface honestly reports the lane is gone rather
  # than shelling out. (Run Go/Zig SOURCE in-sandbox via the language lanes, or
  # fetch a prebuilt wasm via wasm:/archive: #+BUILD_SRC.)
  defp do_build_clause(id, %{exec: exec, build_src: {:gobuild, pkg}})
       when exec in ["command", nil],
       do: "#{id}: native go build of #{pkg} removed (wb-9ja) — no in-sandbox lane for fetching+building an upstream Go package; use a prebuilt wasm:/archive: source or the in-sandbox go SOURCE lane"

  defp do_build_clause(id, %{exec: exec, build_src: {:zigbuild, rel}})
       when exec in ["command", nil],
       do: "#{id}: native zig build of #{rel} removed (wb-9ja) — compile Zig SOURCE in-sandbox via the zig lane instead"

  defp do_build_clause(id, %{exec: exec, build_src: {:script, rel}})
       when exec in ["command", nil],
       do: "#{id}: native build script #{rel} removed (wb-9ja) — native bash build scripts are banned; fetch a prebuilt wasm via wasm:/archive: #+BUILD_SRC"

  defp do_build_clause(id, %{build_src: nil}),
    do: "#{id}: no #+BUILD_SRC declared — nothing to build (declare crate:<name> | path:<dir> | wasm:<url> | archive:<url>)"

  defp do_build_clause(id, %{build_src: {:git, url}}),
    do: "#{id}: #+BUILD_SRC git+#{url} not yet supported by `wb toolkit build` (use crate: or path:)"

  defp do_build_clause(id, %{build_src: {:unknown, spec}}),
    do: "#{id}: unrecognized #+BUILD_SRC #{inspect(spec)} (expected crate:<name> | git+<url> | path:<dir>)"

  defp error_text(reason) when is_binary(reason), do: String.slice(reason, -2000, 2000)
  defp error_text(reason), do: inspect(reason)

  @doc """
  `wb toolkit run <id> <task> -- <args...>` — DISABLED (wb-9ja). A `:role task`
  block is arbitrary NATIVE bash; native execution is banned, and this surface is
  reachable by the in-sandbox agent (its `wb` tool), so it must never run native
  code. The toolkit's CLI is meant to ship as a WASM command (the Dock-gated
  `run-command` path); convert it and invoke that instead.
  """
  def run_task_text(id, task, args, root \\ default_root()) do
    # If this toolkit ships no compiled command (no CLI_BIN / BUILD_SRC), its
    # skills document built-in `wb` verbs — so `toolkit run` was never the right
    # path. Guide the agent to the DIRECT invocation instead of a cryptic refusal
    # (this is the point-of-error self-correction for the toolkit-run confusion).
    case tk_dir(id, root) do
      nil ->
        "no such toolkit: #{id}"

      dir ->
        d = parse_descriptor(File.read!(Path.join(dir, @manifest)))

        # CLI_BIN: wb means the toolkit's "binary" IS the built-in wb — its skills
        # document `wb <verb>` commands (vs a compiled command-toolkit like huniq
        # whose CLI_BIN is its own binary).
        if d.cli_bin == "wb" do
          suggested = String.trim("wb #{task} " <> Enum.join(List.wrap(args), " "))

          "#{id} is a direct-verb toolkit — its skills document built-in `wb` verbs, " <>
            "not a runnable command. Run it DIRECTLY through your `wb` tool: `#{suggested}` " <>
            "(don't use `wb toolkit run` for #{id})."
        else
          "refusing to run #{id}/#{task}: native :role bash execution removed (wb-9ja). " <>
            "Ship the toolkit CLI as a WASM command and run it via the Dock-gated run-command path."
        end
    end
  end

  # Count :role pre blocks across a toolkit's skills (for the verify SKIPPED note).
  defp pre_block_count(dir) do
    Path.wildcard(Path.join([dir, "skills", "**", "*#{@skill_ext}"]))
    |> Enum.filter(&contained?(&1, Path.expand(dir)))
    |> Enum.reduce(0, fn path, acc -> acc + length(extract_role_blocks(File.read!(path), "pre")) end)
  end

  # Is the declared #+EXEC mode satisfiable right now?
  #   command  → CLI_BIN already a registered command, OR a #+BUILD_SRC that can
  #              produce it (so `wb toolkit build` would satisfy it).
  #   posix    → CLI_BIN resolves on PATH.
  #   task     → at least one skill carries a :role task block.
  #   federation → a plugin/ data-source face exists.
  # wb-pkh.6: the #+CAPS cross-check — every declared cap must be GRANTABLE (known
  # to Policy), and at least one profile must grant the WHOLE declared set, else the
  # toolkit can never instantiate (it would import a cap no profile provides). Also
  # report the minimal granting profile(s) so the author knows what to deploy under.
  defp cap_checks(%{caps: []}), do: []

  defp cap_checks(%{caps: caps}) when is_list(caps) do
    known = Workbooks.Policy.profiles() |> Enum.flat_map(&Workbooks.Policy.caps/1) |> MapSet.new()
    unknown = Enum.reject(caps, &MapSet.member?(known, &1))
    granting = Workbooks.Policy.profiles() |> Enum.filter(fn p -> caps -- Workbooks.Policy.caps(p) == [] end)

    known_check =
      if unknown == [],
        do: {true, "caps declared, all grantable: #{Enum.join(caps, " ")}"},
        else: {false, "caps NOT grantable by any profile: #{Enum.join(unknown, " ")}"}

    grant_check =
      if granting == [],
        do: {false, "no single Policy profile grants all declared caps (#{Enum.join(caps, " ")})"},
        else: {true, "granted by profile(s): #{Enum.map_join(granting, ", ", &to_string/1)}"}

    [known_check, grant_check]
  end

  defp cap_checks(_), do: []

  defp exec_checks(%{exec: nil}), do: [{true, "exec: none declared (discovery-only toolkit)"}]

  defp exec_checks(%{exec: "command", cli_bin: bin, build_src: src}) do
    registered? = bin && bin in Workbooks.CommandRegistry.list()
    buildable? = match?({:crate, _}, src) or match?({:path, _}, src)

    cond do
      is_nil(bin) -> [{false, "exec: command but no CLI_BIN declared"}]
      registered? -> [{true, "exec: command — #{bin} registered"}]
      buildable? -> [{true, "exec: command — #{bin} not yet registered, build descriptor present (run `wb toolkit build`)"}]
      true -> [{false, "exec: command — #{bin} not registered and no buildable #+BUILD_SRC"}]
    end
  end

  defp exec_checks(%{exec: "posix", cli_bin: bin}) do
    cond do
      is_nil(bin) -> [{false, "exec: posix but no CLI_BIN declared"}]
      System.find_executable(bin) -> [{true, "exec: posix — #{bin} on PATH"}]
      true -> [{false, "exec: posix — #{bin} not found on PATH"}]
    end
  end

  defp exec_checks(%{exec: "task"}), do: [{true, "exec: task (recipes run via `wb toolkit run`)"}]
  defp exec_checks(%{exec: "federation"}), do: [{true, "exec: federation (data-source/sync faces)"}]

  defp exec_checks(%{exec: "kernel", cli_bin: bin}) do
    if is_binary(bin) and bin in Workbooks.KernelRegistry.list(),
      do: [{true, "exec: kernel — #{bin} registered (open via Workbooks.Kernel / Fabric.map_kernel)"}],
      else: [{true, "exec: kernel — #{bin} not yet built (run `wb toolkit build`)"}]
  end

  defp exec_checks(%{exec: "component"}),
    do: [{true, "exec: component (WIT-typed; built via build_dir, run in-VM via Instance)"}]

  defp exec_checks(%{exec: other}), do: [{false, "exec: unknown mode #{inspect(other)}"}]

  defp tk_dir(id, root) do
    case Enum.find(tk_dirs_lite(root), &(&1.id == id)) do
      %{dir: dir} -> dir
      _ -> nil
    end
  end

  # Lightweight toolkit lister for the release/version verbs: pure filesystem +
  # Floki over the manifest's `<work-toolkit id=…>`, no live runtime needed. id =
  # the manifest's `id` attribute, else the dir name.
  defp tk_dirs_lite(root) do
    Path.wildcard(Path.join(root, "*/#{@manifest}"))
    |> Enum.map(fn manifest ->
      dir = Path.dirname(manifest)
      id = case work_toolkit(File.read!(manifest)) do
             %{attrs: %{"id" => id}} when is_binary(id) and id != "" -> id
             _ -> Path.basename(dir)
           end

      %{id: id, dir: dir}
    end)
  end

  # SECURITY (wb-sec, findings #4/#5): a skill slug is agent/LLM-supplied. It must
  # name a file INSIDE the toolkit's own skills/ dir — never traverse out via "..",
  # a path separator, or an absolute segment. We (1) reject any slug that isn't a
  # bare, dot-dot-free name, and (2) canonicalize the candidate and assert it is
  # strictly contained under <dir>/skills/ before any File access. Both layers are
  # required: charset alone misses symlink/Path quirks; containment alone still
  # lets a `..` candidate that happens to resolve back inside slip valid names.
  @slug_re ~r/^[A-Za-z0-9._-]+$/

  defp safe_slug?(slug),
    do: is_binary(slug) and Regex.match?(@slug_re, slug) and slug not in [".", ".."]

  # thin skill: skills/<slug>.md ; thick skill: skills/<slug>/SKILL.md
  defp skill_path(dir, slug) do
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

  # candidate must canonicalize to a path strictly inside `base` (base itself or
  # a descendant). Path.expand collapses any "." / ".." in the candidate.
  defp contained?(candidate, base) do
    base = Path.expand(base)
    abs = Path.expand(candidate)
    abs == base or String.starts_with?(abs, base <> "/")
  end

  # Read a `<work-toolkit>` attribute (dash-cased lowercase) from a toolkit's
  # manifest. `key` is the legacy UPPER_SNAKE name (TAGLINE/VERSION/…); it maps to
  # the HTML attribute (tagline/version/…), with CLI_BIN → cli.
  defp manifest_kw(dir, key) do
    with {:ok, body} <- File.read(Path.join(dir, @manifest)),
         %{attrs: attrs} <- work_toolkit(body) do
      blank_to_nil(attrs[attr_name(key)])
    else
      _ -> nil
    end
  end

  defp attr_name("CLI_BIN"), do: "cli"
  defp attr_name(key), do: key |> String.downcase() |> String.replace("_", "-")

  # The skill TOC: a Markdown skill's `##` section headings (org `#+CAPTION` →
  # `##` in the work-* model). Each heading becomes a "  • <heading>" TOC bullet.
  defp captions(body),
    do: Regex.scan(~r/^[ \t]*##[ \t]+(.+?)[ \t]*$/m, body) |> Enum.map(fn [_, c] -> String.trim(c) end)

  @doc false
  # Extract the body of every `#+begin_src bash :role <role> …` block.
  def extract_role_blocks(content, role) do
    ~r/#\+begin_src\s+[^\n]*:role\s+#{role}\b[^\n]*\n(.*?)\n\s*#\+end_src/s
    |> Regex.scan(content)
    |> Enum.map(fn [_, body] -> body end)
  end

  # ── NO NATIVE EXECUTION (wb-9ja) ── the :role-bash lane is DISABLED ──────────
  #
  # A :role bash block from a discovered toolkit dir is arbitrary NATIVE bash. The
  # no-native-exec canon makes it IMPOSSIBLE for the in-sandbox agent (and the
  # toolkit verify/eval/run surfaces it reaches via `wb toolkit run`) to execute
  # native code. So this lane no longer shells out at all — `Workbooks.Sandbox`
  # (the old bwrap/seatbelt native isolator) was DELETED, and `run_bash` returns an
  # honest "disabled" result instead of forking bash.
  #
  # SUBSTRATE DISTINCTION: a toolkit's CLI is meant to ship as a WASM command (the
  # Dock-gated `run-command` path — wasmtime running a `.wasm`, which IS the
  # architecture and stays). Native bash from a skill file is the banned thing.
  # Convert the toolkit CLI to a WASM command; this host-bash leg is gone for good.

  @doc "Whether :role bash execution is opted-in. DISABLED (wb-9ja): always false — native exec is banned, regardless of WB_TOOLKIT_EXEC."
  def exec_allowed?, do: false

  # ── Versioned releases (wbx-verbs) ─────────────────────────────────────────
  # A toolkit is mirrored to its own repo and managed as a versioned RELEASE. The
  # available versions come from `toolkits/releases.json` (a release index keyed by
  # toolkit id) UNIONED with the manifest's own `#+VERSION:`/`:VERSION:` — so a
  # toolkit always has at least its in-tree version even before any release lands.
  # The currently-LIVE version is pinned in `toolkits/.live.json`; `rollback`
  # rewrites that pin. Pure-Elixir, no network — these are plain file reads/writes
  # over the toolkits root, mirroring discovery (a toolkit is a directory).

  @doc "`wbx toolkit versions <id>` — available versions/tags for a toolkit (releases.json ∪ manifest VERSION)."
  def versions_text(id, root \\ default_root()) do
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

  @doc """
  `wbx toolkit live [<id>]` — the currently-live version. With an id, that one
  toolkit; without, every toolkit's live pin (the manifest VERSION when unpinned).
  """
  def live_text(id_or_root \\ nil, root \\ default_root())
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

  @doc """
  `wbx toolkit rollback <id> <version>` — set the live version back to an older
  release. Validates the version exists for the toolkit, then writes the pin into
  `toolkits/.live.json` (created/merged in place). Idempotent.
  """
  def rollback_text(id, version, root \\ default_root()) do
    case tk_dir(id, root) do
      nil ->
        "no such toolkit: #{id}"

      dir ->
        vs = available_versions(id, dir, root)

        cond do
          version in [nil, ""] ->
            "rollback #{id}: no version given (try `wbx toolkit versions #{id}`)"

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

  # Version.compare needs valid semver; if any tag isn't, fall back to string sort
  # so non-semver tags (e.g. "v1", "edge") still list deterministically.
  defp sort_fallback(vs) do
    if Enum.all?(vs, &match?({:ok, _}, Version.parse(&1))),
      do: vs,
      else: Enum.sort(vs, :desc)
  end

  # The live version for a toolkit: the .live.json pin, else nil (caller falls
  # back to the manifest VERSION — the natural "live = what's in tree" default).
  defp live_version(id, root), do: live_pins(root)[id]

  defp pinned?(id, root), do: Map.has_key?(live_pins(root), id)

  defp manifest_version(dir), do: manifest_kw(dir, "VERSION")

  # toolkits/releases.json — the release index (id → versions). Absent/corrupt → %{}.
  defp releases(root) do
    read_json(Path.join(root, "releases.json"))
  end

  # toolkits/.live.json — the live-version pins (id → version). Absent/corrupt → %{}.
  defp live_pins(root) do
    read_json(Path.join(root, ".live.json"))
  end

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

  # ── <work-toolkit> HTML reader (Floki) ────────────────────────────────────
  # The manifest is a single `<work-toolkit>` element. Its attributes carry what
  # the org keywords used to (id/cli/version/status/tagline/requires/exec/…); the
  # nested `<work-doc>` body is the front-door prose. One parser, attribute-named.

  # Parse a manifest's HTML → the `<work-toolkit>` element nodes (attrs map + body).
  defp work_toolkit_nodes(html) do
    case Floki.parse_fragment(html) do
      {:ok, tree} -> Floki.find(tree, "work-toolkit") |> Enum.map(&node_of/1)
      {:error, _} -> []
    end
  end

  defp node_of({"work-toolkit", attrs, children}) do
    %{attrs: Map.new(attrs), doc: Floki.find(children, "work-doc") |> Floki.text() |> String.trim()}
  end

  # The first `<work-toolkit>` in a manifest body, or nil. Cached read shape used
  # by the keyword/descriptor accessors below.
  defp work_toolkit(body) do
    case work_toolkit_nodes(body) do
      [n | _] -> n
      [] -> nil
    end
  end

  defp view(%{attrs: a}) do
    %{
      id: a["id"],
      title: a["title"],
      version: a["version"],
      cli: a["cli"],
      status: a["status"],
      skill_dir: a["skill-dir"]
    }
  end
end
