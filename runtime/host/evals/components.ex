defmodule Workbooks.Evals.Components do
  @moduledoc """
  The component-emit eval pack runner (`runtime/evals/components/`).

  Reuses the existing eval machinery — the same agent (`Workbooks.Agent.run`),
  the same LLM judge brain (`Workbooks.Llm.complete`), and the wavelet spec
  shape (YAML frontmatter + `checks[]` + an inline markdown rubric). It is NOT a
  new runner: it parses the spec, runs the agent on the adversarial one-liner,
  extracts the emitted component artifact, MOUNTS that artifact headless and
  screenshots it light + dark (the one new path), then attaches the two frames
  to the vision judge and runs the deterministic component checks.

  Artifact under test: the agent's `#+RENDER: org` + `#+begin_src component
  :type …` block, and/or HTML mounting `work-*` elements. The catalog the agent
  chooses from is the CEM (`workponents/custom-elements.json`, 42 tags).

  Voice parity: the SAME prompt is run through the rehearsed VOICE path (a
  one-sentence reply + a component emit, no ElevenLabs/Inworld key) and the
  chosen `work-*` tag must MATCH the text agent's choice — divergence is a fail.

      Workbooks.Evals.Components.run("chart-not-table")   # one case
      Workbooks.Evals.Components.run()                    # whole pack
  """
  require Logger
  alias Workbooks.Browse.Headless

  @root Path.expand("../../evals/components", __DIR__)
  # The product/eval model: Minimax M3 (override WB_EVAL_MODEL). The cheap platform
  # default (mimo) + the full agent tool-loop thrashes (web-searches trivial briefs
  # ~2.5min/step); this eval measures COMPOSITION, so it pins the product model and
  # runs emit-only.
  @eval_model "minimax/minimax-m3"
  # Chart variants the model emits as `:type` (bar/line/…) — all resolve to work-chart,
  # the variant kept as the element's `type` attr. (Defined here, before first use —
  # module attributes read in source order.)
  @chart_variants ~w(bar line area scatter column donut pie)

  # ── public surface ─────────────────────────────────────────────────────────

  @doc "Run the whole pack (all specs). Returns a summary string."
  def run, do: run(nil)

  @doc "Run one case (substring of the spec filename) or all (nil)."
  def run(filter, opts \\ []) do
    specs =
      Path.wildcard(Path.join([@root, "specs", "*.eval.md"]))
      |> Enum.filter(&(is_nil(filter) or String.contains?(Path.basename(&1), filter)))
      |> Enum.sort()

    cond do
      specs == [] and filter ->
        "components: no spec matches #{inspect(filter)}"

      specs == [] ->
        "components: no specs under #{@root}/specs"

      true ->
        results = Enum.map(specs, &run_spec(&1, opts))
        pass = Enum.count(results, &(elem(&1, 0) == :pass))
        skip = Enum.count(results, &(elem(&1, 0) == :skip))
        n = length(results)
        sk = if skip > 0, do: " (#{skip} skipped)", else: ""

        "components evals: #{pass}/#{n - skip} passed#{sk}\n" <>
          Enum.map_join(results, "\n", fn {st, label} ->
            "  #{%{pass: "✓", fail: "✗", skip: "·"}[st]} #{label}"
          end)
    end
  end

  # ── one spec ─────────────────────────────────────────────────────────────

  defp run_spec(path, opts) do
    name = Path.basename(path, ".eval.md")
    spec = parse_spec(File.read!(path))
    turn = List.first(spec.turns) || %{}
    prompt = turn["prompt"] || turn[:prompt] || ""
    checks = turn["checks"] || turn[:checks] || []

    cond do
      # `stub_emit` proves the harness wiring (parse → extract → checks → mount
      # → screenshot → judge) WITHOUT a live model, for CI/dev smoke. A live run
      # omits it and exercises the real agent.
      is_nil(opts[:stub_emit]) and not llm_key?() ->
        {:skip, "#{name}: SKIPPED (no LLM key — set OPENROUTER_API_KEY / WB_LLM_KEY)"}

      prompt == "" ->
        {:fail, "#{name}: spec has no turn prompt"}

      true ->
        run_dir = run_dir(name)
        File.mkdir_p!(run_dir)

        # 1. TEXT agent: run the adversarial one-liner, get the emitted message.
        emit = opts[:stub_emit] || agent_emit(text_system(), prompt, opts)
        File.write!(Path.join(run_dir, "emit.org"), emit)
        artifact = extract_component(emit)

        # 2. Deterministic component checks on the emitted artifact.
        det = Enum.map(checks, &run_check(&1, artifact, emit, opts))

        # 3. Mount the artifact headless, screenshot light + dark.
        frames = mount_and_shoot(artifact, run_dir)

        # 4. Vision rubric (if a rubric.passes check is present + frames exist).
        #    Skipped only when no LLM key is reachable (the deterministic checks
        #    + the mounted frames still prove the harness).
        rub = if llm_key?(), do: run_rubric(checks, emit, frames), else: []

        all = Enum.reject(det ++ rub, &is_nil/1)
        write_verdict(run_dir, name, spec, artifact, frames, all)

        failed = Enum.filter(all, fn {_k, ok, _d} -> not ok end)
        label = "#{name} → tag=#{artifact.tag || "none"} " <> summarize(all)

        if failed == [], do: {:pass, label}, else: {:fail, label}
    end
  end

  # ── spec parser ──────────────────────────────────────────────────────────────
  #
  # A purpose-built parser for THIS pack's spec shape (no YAML dep in the
  # runtime; adding one for a 7-file pack violates least-code). Mirrors the
  # wavelet frontmatter shape — `name`, `agent`, `turns[].prompt`,
  # `turns[].checks[]`, and the inline `rubric:` block literal. The frontmatter
  # is between the leading `---` fences; everything after is prose (ignored).
  @doc false
  def parse_spec(text) do
    fm =
      case Regex.run(~r/\A---\n(.*?)\n---/ms, text) do
        [_, body] -> body
        _ -> ""
      end

    %{
      name: scalar(fm, "name"),
      agent: scalar(fm, "agent"),
      turns: parse_turns(fm)
    }
  end

  defp scalar(fm, key) do
    case Regex.run(~r/^#{key}:\s*(.+?)\s*$/m, fm) do
      [_, v] -> unquote_str(v)
      _ -> nil
    end
  end

  # One turn per `  - prompt:` entry. Prompt may be a scalar or a `|` block.
  # Each turn's `checks:` list is parsed into maps keyed by string.
  defp parse_turns(fm) do
    case Regex.run(~r/^turns:\n(.*)\z/ms, fm) do
      [_, block] ->
        # split into turn chunks at the `  - ` list-item indent
        chunks =
          block
          |> String.split(~r/^  - /m, trim: true)
          |> Enum.map(&("  - " <> &1))

        Enum.map(chunks, &parse_turn/1)

      _ ->
        []
    end
  end

  defp parse_turn(chunk) do
    %{
      "prompt" => parse_block_or_scalar(chunk, "prompt"),
      "checks" => parse_checks(chunk)
    }
  end

  # `prompt: scalar`  OR  `prompt: |` + indented lines.
  defp parse_block_or_scalar(chunk, key) do
    cond do
      m = Regex.run(~r/#{key}:\s*\|\s*\n((?:[ \t]+.*\n?)+)/m, chunk) ->
        [_, body] = m
        body
        |> String.split("\n")
        |> Enum.map(&String.replace(&1, ~r/^      /, ""))
        |> Enum.join("\n")
        |> String.trim_trailing()

      m = Regex.run(~r/#{key}:\s*"((?:[^"\\]|\\.)*)"/, chunk) ->
        [_, v] = m
        v

      m = Regex.run(~r/#{key}:\s*(.+?)\s*$/m, chunk) ->
        [_, v] = m
        unquote_str(v)

      true ->
        nil
    end
  end

  # Each `      - kind: …` under `checks:` is one check. We capture the kind +
  # the simple scalar/list fields the deterministic checks read. The `rubric: |`
  # block (only on rubric.passes) is captured whole.
  defp parse_checks(chunk) do
    case Regex.run(~r/checks:\n(.*)\z/ms, chunk) do
      [_, block] ->
        block
        |> String.split(~r/^      - kind:/m, trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(&parse_check("kind:" <> &1))

      _ ->
        []
    end
  end

  defp parse_check(body) do
    base = %{
      "kind" => scalar_in(body, "kind"),
      "expect" => scalar_in(body, "expect"),
      "prompt" => parse_block_or_scalar(body, "prompt"),
      "target" => scalar_in(body, "target"),
      "minScore" => num_in(body, "minScore"),
      "strict" => scalar_in(body, "strict") == "true",
      "any_of" => list_in(body, "any_of"),
      "forbid" => list_in(body, "forbid"),
      "contains_values" => list_in(body, "contains_values")
    }

    rubric =
      case Regex.run(~r/rubric:\s*\|\s*\n(.*)\z/ms, body) do
        [_, r] ->
          r
          |> String.split("\n")
          |> Enum.map(&String.replace(&1, ~r/^          /, ""))
          |> Enum.join("\n")
          |> String.trim()

        _ ->
          nil
      end

    Map.put(base, "rubric", rubric)
  end

  defp scalar_in(body, key) do
    case Regex.run(~r/^\s*#{key}:\s*(.+?)\s*$/m, body) do
      [_, v] -> unquote_str(v)
      _ -> nil
    end
  end

  defp num_in(body, key) do
    case scalar_in(body, key) do
      nil ->
        nil

      v ->
        case Float.parse(v) do
          {n, _} -> n
          _ -> nil
        end
    end
  end

  # `any_of: [work-chart, work-table]` (flow) or a `-` block list.
  defp list_in(body, key) do
    cond do
      m = Regex.run(~r/^\s*#{key}:\s*\[(.*?)\]/m, body) ->
        [_, inner] = m
        inner |> String.split(",") |> Enum.map(&unquote_str(String.trim(&1))) |> Enum.reject(&(&1 == ""))

      m = Regex.run(~r/^\s*#{key}:\s*\n((?:\s*-\s*.+\n?)+)/m, body) ->
        [_, blk] = m
        Regex.scan(~r/-\s*(.+)/, blk) |> Enum.map(fn [_, v] -> unquote_str(String.trim(v)) end)

      true ->
        []
    end
  end

  defp unquote_str(v) do
    v |> String.trim() |> String.trim_leading("\"") |> String.trim_trailing("\"")
  end

  # ── the checks ─────────────────────────────────────────────────────────────

  # component.emits_tag — the agent reached for an allowed tag, none of the forbidden.
  defp run_check(%{"kind" => "component.emits_tag"} = c, art, _emit, _opts) do
    any = c["any_of"] || []
    forbid = c["forbid"] || []
    tag = art.tag

    cond do
      tag == nil ->
        {"emits_tag", false, "no component/work-* tag in the emit"}

      tag in forbid ->
        {"emits_tag", false, "emitted forbidden tag #{tag}"}

      any == [] or tag in any ->
        {"emits_tag", true, "tag=#{tag}"}

      true ->
        {"emits_tag", false, "tag=#{tag} not in #{inspect(any)}"}
    end
  end

  # component.binds_data — data carried in the block (rows/csv/query/numbers),
  # and (when contains_values is set) the supplied values round-trip.
  defp run_check(%{"kind" => "component.binds_data"} = c, art, _emit, _opts) do
    body = art.raw || ""
    has_numeric = Regex.match?(~r/\d/, body)
    has_seam = Regex.match?(~r/(rows|csv|query|data|series)\b/i, body) or art.tag in ["work-chart", "work-table", "work-metric", "work-spark"]

    want = c["contains_values"] || []
    missing = Enum.reject(want, &String.contains?(body, &1))

    cond do
      want != [] and missing != [] ->
        {"binds_data", false, "supplied values missing: #{inspect(missing)}"}

      c["expect"] == "numeric_series" and not has_numeric ->
        {"binds_data", false, "no numeric series bound"}

      not has_seam ->
        {"binds_data", false, "no data seam (rows/csv/query/data) in block"}

      true ->
        {"binds_data", true, "data bound via the prop/host seam"}
    end
  end

  # component.themes_from_tokens — no literal colors in the artifact.
  defp run_check(%{"kind" => "component.themes_from_tokens"} = c, art, _emit, _opts) do
    body = art.raw || ""
    literals = literal_colors(body)
    strict = c["strict"] == true

    cond do
      literals == [] ->
        {"themes_from_tokens", true, "no literal colors"}

      strict ->
        {"themes_from_tokens", false, "literal colors (strict): #{inspect(Enum.take(literals, 3))}"}

      true ->
        # non-strict: a stray literal is a soft note; theme_compliance dim still
        # weighs the light/dark frame delta in the rubric.
        {"themes_from_tokens", true, "soft: literal colors present #{inspect(Enum.take(literals, 3))}"}
    end
  end

  # voice.component_parity — the rehearsed voice path picks the SAME tag.
  defp run_check(%{"kind" => "voice.component_parity"} = c, art, _emit, opts) do
    prompt = c["prompt"] || ""
    vemit = opts[:stub_voice_emit] || agent_emit(voice_system(), prompt, opts)
    vtag = extract_component(vemit).tag

    cond do
      art.tag == nil ->
        {"voice_parity", false, "text agent chose no tag — nothing to match"}

      vtag == art.tag ->
        {"voice_parity", true, "voice and text agree on #{vtag}"}

      true ->
        {"voice_parity", false, "divergence: text=#{art.tag} voice=#{vtag || "none"}"}
    end
  end

  # rubric.passes is handled separately (needs frames); ignore here.
  defp run_check(%{"kind" => "rubric.passes"}, _art, _emit, _opts), do: nil
  defp run_check(_other, _art, _emit, _opts), do: nil

  # ── vision rubric ───────────────────────────────────────────────────────────

  defp run_rubric(checks, emit, frames) do
    case Enum.find(checks, &(&1["kind"] == "rubric.passes")) do
      nil ->
        []

      rc ->
        rubric = rc["rubric"] || ""
        min = rc["minScore"] || 0.66

        {ok, detail} = vision_judge(emit, rubric, frames)
        score_note = if ok, do: "rubric PASS", else: "rubric FAIL"
        # honor minScore semantics loosely: the judge returns PASS/FAIL on the
        # spec's own threshold; minScore is recorded for the verdict.
        _ = min
        [{"rubric.passes", ok, "#{score_note} — #{detail}"}]
    end
  end

  defp vision_judge(emit, rubric, frames) do
    sys =
      "You are a strict UI eval judge. You are given a component eval RUBRIC, " <>
        "the agent's EMITTED message (org/component source), and up to two rendered " <>
        "FRAMES (the emitted component mounted light + dark). Score every dimension " <>
        "in the rubric 0-3 and apply its threshold. Respond with a FIRST line that is " <>
        "exactly PASS or FAIL, then one short line of reasoning."

    text =
      "RUBRIC:\n#{rubric}\n\nAGENT EMITTED MESSAGE:\n#{String.slice(emit, 0, 4000)}\n\n" <>
        frame_note(frames)

    content =
      [%{type: "text", text: text}] ++
        Enum.flat_map(frames, fn {label, png} ->
          case data_url(png) do
            nil -> []
            url -> [%{type: "text", text: "Frame: #{label}"}, %{type: "image_url", image_url: %{url: url}}]
          end
        end)

    msgs = [%{role: "system", content: sys}, %{role: "user", content: content}]

    case Workbooks.Llm.complete(msgs, []) do
      {:ok, %{content: c}} when is_binary(c) ->
        first = c |> String.split("\n", trim: true) |> List.first() |> to_string() |> String.upcase() |> String.trim()
        {String.starts_with?(first, "PASS"), String.trim(String.slice(c, 0, 240))}

      other ->
        {false, "judge error: #{inspect(other)}"}
    end
  end

  defp frame_note([]), do: "(no frames — headless browser unavailable; score render_fidelity from the emitted source structure only and note the limitation.)"
  defp frame_note(_), do: "(two frames attached: light then dark.)"

  defp data_url(png) do
    case File.read(png) do
      {:ok, bin} when byte_size(bin) > 0 -> "data:image/png;base64," <> Base.encode64(bin)
      _ -> nil
    end
  end

  # ── mount + screenshot ───────────────────────────────────────────────────────

  # Write a self-contained mount page per theme, screenshot each. Returns
  # [{"light", path}, {"dark", path}] for frames that rendered; [] if the
  # headless browser is unavailable (the judge then scores from source only).
  defp mount_and_shoot(%{tag: nil}, _dir), do: []

  defp mount_and_shoot(art, dir) do
    if Headless.available?() do
      Enum.flat_map(["light", "dark"], fn theme ->
        html = mount_html(art, theme)
        html_path = Path.join(dir, "mount.#{theme}.html")
        png_path = Path.join(dir, "mount.#{theme}.png")
        File.write!(html_path, html)

        case Headless.screenshot("file://" <> html_path, png_path) do
          {:ok, _} -> [{theme, png_path}]
          {:error, reason} -> Logger.warning("components-eval: screenshot #{theme} failed: #{inspect(reason)}"); []
        end
      end)
    else
      []
    end
  end

  # The mount page: the --work-* token sheet for ONE theme + the registered
  # workponents elements (importmap → src) when present, then the emitted block.
  # Falls back to a visible stub card (tag + bound data) when the element source
  # isn't built — the frame still proves the headless path + the agent's choice.
  defp mount_html(art, theme) do
    tokens = token_sheet()
    # Prefer the self-contained dist bundle: Lit is bundled IN, so it imports from
    # file:// offline (the lazy CDN engine tiers stay lazy → the element FLOOR
    # renders — real chrome, not a stub card). The src/elements path uses a bare
    # `import "lit"` that can't resolve from file:// offline, so it's not a usable
    # fallback here; build dist first (`cd workponents && npm run build`).
    dist = Path.expand("../../../workponents/dist/workponents.js", __DIR__)
    has_dist = File.exists?(dist)

    mount_body =
      if String.starts_with?(art.raw || "", "<") and String.contains?(art.raw, "work-") do
        art.raw
      else
        # component-block form → reconstruct the work-* element from {tag, props, body}
        attrs = Enum.map_join(art.props, " ", fn {k, v} -> ~s(#{k}="#{esc(v)}") end)
        ~s(<#{art.tag} #{attrs}>#{esc(art.body || "")}</#{art.tag}>)
      end

    loader =
      if has_dist do
        # INLINE the bundle source — both `import("file://…")` and
        # `<script src="file://…">` are CORS-blocked from a file:// page (origin
        # null), so the only offline path is inlining the module text. `</script`
        # is neutralized so the bundle can't close its own tag. Lit is bundled in;
        # the lazy CDN engine tiers stay dynamic imports (fail offline → floor).
        bundle = File.read!(dist) |> String.replace("</script", "<\\/script")
        "<script type=\"module\">\n#{bundle}\n</script>"
      else
        # stub: a token-themed card showing the chosen tag + payload so the
        # frame is non-blank and theme-honest WITHOUT the built bundle.
        stub_script(art)
      end

    """
    <!doctype html><html data-work-theme="#{theme}"><head><meta charset="utf-8">
    <!-- Block external scripts/connections so the powered tiers' CDN import() FAILS
         FAST (no network hang) → the element floor renders deterministically before
         the screenshot. 'unsafe-inline' keeps the inlined bundle + styles working. -->
    <meta http-equiv="Content-Security-Policy" content="default-src 'unsafe-inline' data: blob:; connect-src 'none'">
    <style>#{tokens}
    html,body{margin:0;background:var(--work-bg);color:var(--work-fg);font-family:var(--work-font);}
    .mount{padding:24px;min-height:100vh;box-sizing:border-box;}
    </style></head>
    <body><div class="mount">#{mount_body}</div>#{loader}</body></html>
    """
  end

  # Minimal stub: if the real elements aren't built, define lightweight
  # custom elements that render a token-themed card naming the tag + payload.
  defp stub_script(_art) do
    js = ~S"""
    <script>
      const TAGS = __TAGS__;
      class Stub extends HTMLElement {
        connectedCallback(){
          const t = this.tagName.toLowerCase();
          const body = (this.textContent||"").trim();
          const attrs = [...this.attributes].map(a=>a.name+"="+a.value).join("  ");
          this.attachShadow({mode:"open"}).innerHTML =
            `<style>.c{background:var(--work-surface);border:1px solid var(--work-border);
              border-radius:var(--work-radius,12px);padding:16px;box-shadow:var(--work-shadow);}
              .t{color:var(--work-brand);font-weight:600;font-size:var(--work-text-lg,16px);}
              .a{color:var(--work-fg-muted);font-size:var(--work-text-sm,12px);margin-top:6px;white-space:pre-wrap;}
              .b{color:var(--work-fg);margin-top:8px;white-space:pre-wrap;}</style>
             <div class="c"><div class="t">&lt;${t}&gt;</div><div class="a">${attrs}</div><div class="b">${body}</div></div>`;
        }
      }
      for (const t of TAGS) { if(!customElements.get(t)) customElements.define(t, class extends Stub{}); }
    </script>
    """

    String.replace(js, "__TAGS__", Jason.encode!(known_tags()))
  end

  # ── agent emit ──────────────────────────────────────────────────────────────

  # Emit one component for a prompt and return the message text. EMIT-ONLY: a direct
  # LLM completion with NO search/shell tool loop — this eval measures the agent's
  # COMPOSITION (does it reach for + correctly author the right element), not its
  # tool-using behavior. (The full agent loop web-searches trivial briefs and
  # thrashes; that's a separate integration concern.) Model: opts → WB_EVAL_MODEL →
  # the capable @eval_model default (never the cheap platform default here).
  defp agent_emit(system, prompt, opts) do
    model = opts[:model] || System.get_env("WB_EVAL_MODEL") || @eval_model

    # Use the REAL production catalog Waldo sees (the discovered work-* surface +
    # the data-binding contract), not an eval-local copy — so we audit the actual
    # agent context. Falls back to the eval-local catalog if the toolkit isn't on
    # disk (keeps the eval runnable in a bare checkout).
    catalog =
      case Workbooks.Toolkits.component_catalog(["workponents"]) do
        "" -> catalog_injection()
        real -> real
      end

    messages = [
      %{role: "system", content: system <> "\n\n" <> catalog},
      %{role: "user", content: prompt}
    ]

    case Workbooks.Llm.complete(messages, model: model) do
      {:ok, %{content: content}} -> content || ""
      {:error, reason} -> "(llm error: #{inspect(reason)})"
    end
  rescue
    e -> "(agent error: #{Exception.message(e)})"
  end

  # The text-agent system prompt (Waldo's rich-reply contract, abbreviated).
  defp text_system do
    "You are Waldo, the user's resident assistant inside Workbooks. When a " <>
      "structured or visual answer helps, begin your message with `#+RENDER: org` " <>
      "on its own first line and emit a component block:\n" <>
      "  #+begin_src component :type <type> :<prop> <value>\n  <payload>\n  #+end_src\n" <>
      "Choose the component TYPE that fits the data shape (see the catalog). " <>
      "When data is supplied, bind it faithfully; when NONE is supplied, populate the " <>
      "component with clearly-illustrative sample data rather than asking for data — " <>
      "emit the artifact. Theme only from --work-* tokens — never hardcode colors. " <>
      "Reach for exactly one component; keep prose minimal."
  end

  # The voice-agent system prompt: one-sentence spoken reply + the SAME emit.
  defp voice_system do
    "You are Waldo on a VOICE call. Speak ONE short sentence, then — when a " <>
      "visual answer helps — emit a component artifact the screen will render: " <>
      "begin a `#+RENDER: org` block and a `#+begin_src component :type <type>` block, " <>
      "choosing the TYPE that fits the data shape (see the catalog). " <>
      "Bind real data; theme only from --work-* tokens; one component only."
  end

  # The discovered catalog: the `:type` choices map onto work-* tags from the CEM.
  defp catalog_injection do
    "COMPONENT CATALOG (choose the right element for the data shape):\n" <>
      "- numeric series over a category → :type chart   (work-chart)\n" <>
      "- a list of records / rows with fields → :type table   (work-table)\n" <>
      "- a single point-in-time KPI / scalar → :type metric   (work-metric/work-spark)\n" <>
      "- what changed (before/after) → :type diff   (work-diff)\n" <>
      "- a revision / version history → :type history   (work-history-graph)\n" <>
      "- a short status note → :type callout ; key/value facts → :type kv\n" <>
      "Full element catalog with ATTRIBUTES (use these exact prop names — e.g. " <>
      "work-metric uses `delta` not `change`, work-chart uses `rows` not `data`):\n" <>
      catalog_with_attrs() <>
      "Map your :type to the matching work-* element; do NOT answer a numeric " <>
      "series with a markdown table, a scalar with a full chart, or a diff with raw text."
  end

  # Per-tag attribute lines from the CEM, so the model emits REAL prop names (the
  # tag-names-only catalog made it invent `:change`/`:data`). `tag(attr, attr, …)`.
  defp catalog_with_attrs do
    tag_attrs()
    |> Enum.sort_by(fn {tag, _} -> tag end)
    |> Enum.map_join("\n", fn
      {tag, []} -> "  #{tag}"
      {tag, attrs} -> "  #{tag}(#{Enum.join(attrs, ", ")})"
    end)
    |> Kernel.<>("\n")
  end

  # tagName → [attribute names] from the CEM (empty list if none / unreadable).
  defp tag_attrs do
    cem = Path.expand("../../../workponents/custom-elements.json", __DIR__)

    with {:ok, json} <- File.read(cem),
         {:ok, %{"modules" => mods}} <- Jason.decode(json) do
      mods
      |> Enum.flat_map(fn m -> m["declarations"] || [] end)
      |> Enum.filter(&is_binary(&1["tagName"]))
      |> Map.new(fn d ->
        attrs = (d["attributes"] || []) |> Enum.map(& &1["name"]) |> Enum.filter(&is_binary/1)
        {d["tagName"], attrs}
      end)
    else
      _ -> Map.new(default_tags(), &{&1, []})
    end
  end

  # ── artifact extraction ──────────────────────────────────────────────────────

  # Extract the component the agent emitted. Returns
  # %{tag, props, body, raw} — tag is a work-* tag (nil if none found).
  # Handles BOTH the `#+begin_src component :type …` block and raw `<work-*>` HTML.
  def extract_component(text) when is_binary(text) do
    cond do
      m = Regex.run(~r/#\+begin_src component[ \t]*(.*?)\n[ \t]*#\+end_src/ms, text) ->
        [_, block] = m
        # Parse the WHOLE block (not just the first line) so multi-line data props
        # like `:rows [ … ]` / `:columns [ … ]` land in PROPS (→ the element's
        # attribute) instead of leaking into the body as raw text — the bug that
        # made <work-table> mount empty with the JSON shown as source.
        {props, body} = parse_block(block)
        # type is a single token — guard against any value over-capture (e.g. a
        # `:type doc` block whose prose has no `:`-prefixed lines).
        type = props["type"] && (props["type"] |> String.split() |> List.first())
        tag = type_to_tag(type)

        # For work-chart the `type` value is the chart VARIANT (bar/line/area) the
        # element reads to render — keep it as an attribute; for every other tag
        # `type` was just the selector, so drop it.
        props =
          if tag == "work-chart" and type in @chart_variants,
            do: Map.put(props, "type", type),
            else: Map.delete(props, "type")

        # Normalize the model's data-emit variance onto the element's real attrs
        # (work-chart/table/spark all accept rows | csv): `:data` → rows, and a
        # CSV body → the `csv` attr. Without this, data emitted as CSV-in-body or
        # `:data` never reaches the element → "engine error" → blank chart.
        {props, body} = normalize_data(props, body)

        %{tag: tag, props: props, body: body, raw: block}

      m = Regex.run(~r/<(work-[a-z-]+)\b([^>]*)>(.*?)<\/\1>/ms, text) ->
        [raw, tag, attrs, body] = m
        %{tag: tag, props: parse_attrs(attrs), body: String.trim(body || ""), raw: raw}

      m = Regex.run(~r/<(work-[a-z-]+)\b([^>]*)\/>/ms, text) ->
        [raw, tag, attrs] = m
        %{tag: tag, props: parse_attrs(attrs), body: "", raw: raw}

      # markdown table (the adversarial WRONG answer for chart cases) — surface it
      Regex.match?(~r/^\s*\|.*\|\s*$\n\s*\|[\s:|-]+\|/m, text) ->
        %{tag: "markdown-table", props: %{}, body: "", raw: text}

      true ->
        %{tag: nil, props: %{}, body: "", raw: ""}
    end
  end

  def extract_component(_), do: %{tag: nil, props: %{}, body: "", raw: ""}

  # :type → work-* tag (the discovery mapping the catalog teaches).
  defp type_to_tag(nil), do: nil

  defp type_to_tag(t) do
    case String.downcase(t) do
      "chart" -> "work-chart"
      "table" -> "work-table"
      "metric" -> "work-metric"
      "spark" -> "work-spark"
      "diff" -> "work-diff"
      "history" -> "work-history-graph"
      "history-graph" -> "work-history-graph"
      # chart VARIANTS the model emits as `:type` (instead of `:type chart :variant
      # bar`) all resolve to work-chart — the variant is kept as the `type` attr below.
      v when v in ~w(bar line area scatter column donut pie) -> "work-chart"
      other -> if String.starts_with?(other, "work-"), do: other, else: "work-" <> other
    end
  end

  # `:type chart :tone info` → %{"type" => "chart", "tone" => "info"}
  # Parse a `#+begin_src component` block into {props, body}. Each `:key value`
  # captures its value up to the NEXT line-leading `:key` (or block end), so a
  # multi-line JSON value (`:rows [\n…\n]`) is one prop. The non-prop remainder is
  # the body (e.g. a `:type doc` block's markdown), so data → attribute, prose → text.
  # Map the model's varied data shapes onto the element's real attributes. `:data`
  # (array) aliases to `rows`; a CSV body (header + comma rows) becomes the `csv`
  # attr (work-chart/table/spark all parse `rows` | `csv`). No-op for prose bodies.
  defp normalize_data(props, body) do
    props =
      if is_nil(props["rows"]) and is_binary(props["data"]),
        do: props |> Map.put("rows", props["data"]) |> Map.delete("data"),
        else: props

    if is_nil(props["rows"]) and is_nil(props["csv"]) and csv_like?(body) do
      {Map.put(props, "csv", String.trim(body)), ""}
    else
      {props, body}
    end
  end

  defp csv_like?(body) when is_binary(body) do
    lines = body |> String.trim() |> String.split("\n", trim: true)
    length(lines) >= 2 and Enum.all?(lines, &String.contains?(&1, ",")) and not String.contains?(body, "{")
  end

  defp csv_like?(_), do: false

  # Two passes, so trailing non-prop content (a CSV/prose body) is NOT swallowed into
  # the last prop's value:
  #   1. the HEADER line's INLINE props (`:type chart :x region :y rev`) — each value
  #      runs to the next ` :key ` or end-of-line.
  #   2. LINE-LEADING props in the remaining lines (`:rows [\n…\n]`) — value runs to
  #      the next line-leading `:key` or end (so multi-line JSON is one prop).
  # Lines in the remainder that don't start with `:` are the BODY (CSV/markdown).
  @inline_prop ~r/:([a-z_-]+)[ \t]*(.*?)(?=[ \t]+:[a-z_-]+[ \t]|\z)/s
  @lead_prop ~r/(?:\A|\n)[ \t]*:([a-z_-]+)[ \t]*(.*?)(?=\n[ \t]*:[a-z_-]+|\z)/s

  defp parse_block(block) do
    {header, rest} =
      case String.split(String.trim_leading(block), "\n", parts: 2) do
        [h, r] -> {h, r}
        [h] -> {h, ""}
      end

    inline = Regex.scan(@inline_prop, header) |> Map.new(fn [_, k, v] -> {k, String.trim(v)} end)
    lead = Regex.scan(@lead_prop, rest) |> Map.new(fn [_, k, v] -> {k, String.trim(v)} end)
    body = @lead_prop |> Regex.replace(rest, "") |> String.trim()

    {Map.merge(lead, inline), body}
  end

  defp parse_attrs(a) do
    Regex.scan(~r/([a-z-]+)="([^"]*)"/, a)
    |> Map.new(fn [_, k, v] -> {k, v} end)
  end

  # ── helpers ──────────────────────────────────────────────────────────────────

  # Literal color usage in an artifact (hex / rgb() / hsl()), excluding tokens.
  defp literal_colors(body) do
    Regex.scan(~r/#[0-9a-fA-F]{3,8}\b|rgba?\([^)]*\)|hsla?\([^)]*\)/, body)
    |> Enum.map(&List.first/1)
    |> Enum.uniq()
  end

  defp known_tags do
    cem = Path.expand("../../../workponents/custom-elements.json", __DIR__)

    case File.read(cem) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{"modules" => mods}} ->
            mods
            |> Enum.flat_map(fn m -> m["declarations"] || [] end)
            |> Enum.map(& &1["tagName"])
            |> Enum.filter(&is_binary/1)
            |> Enum.uniq()

          _ -> default_tags()
        end

      _ -> default_tags()
    end
  end

  defp default_tags,
    do: ~w(work-chart work-table work-metric work-spark work-diff work-history-graph work-button)

  defp token_sheet do
    css = Path.expand("../../../workponents/src/theme/tokens.css", __DIR__)

    case File.read(css) do
      {:ok, c} -> c
      _ -> ":root{--work-bg:#fff;--work-fg:#111;--work-brand:#13d943;--work-surface:#fff;--work-border:#ccc;}"
    end
  end

  defp esc(s) when is_binary(s), do: s |> String.replace("\"", "&quot;") |> String.replace("<", "&lt;")
  defp esc(s), do: to_string(s)

  defp summarize(checks) do
    checks
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(" ", fn {k, ok, _d} -> "#{k}:#{if ok, do: "✓", else: "✗"}" end)
  end

  defp run_dir(name) do
    ts = Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%S")
    Path.join([@root, "runs", "#{name}-#{ts}"])
  end

  defp write_verdict(dir, name, _spec, art, frames, checks) do
    rows =
      checks
      |> Enum.reject(&is_nil/1)
      |> Enum.map_join("\n", fn {k, ok, d} -> "| #{k} | #{if ok, do: "PASS", else: "FAIL"} | #{d} |" end)

    verdict = if Enum.all?(checks, fn c -> is_nil(c) or elem(c, 1) end), do: "PASS", else: "FAIL"
    frame_lines = Enum.map_join(frames, "\n", fn {l, p} -> "- #{l}: `#{Path.basename(p)}`" end)

    body = """
    # Verdict — #{name}

    **Verdict:** #{verdict}
    **Chosen tag:** #{art.tag || "none"}

    ## Checks
    | Check | Result | Detail |
    |-------|--------|--------|
    #{rows}

    ## Frames
    #{if frame_lines == "", do: "(none — headless browser unavailable)", else: frame_lines}

    ## Emitted block
    ```
    #{String.slice(art.raw || "", 0, 2000)}
    ```
    """

    File.write!(Path.join(dir, "verdict.md"), body)
  end

  defp llm_key?,
    do:
      Workbooks.Secrets.get("OPENROUTER_API_KEY") not in [nil, ""] or
        System.get_env("WB_LLM_KEY") not in [nil, ""] or
        System.get_env("OPENROUTER_API_KEY") not in [nil, ""]
end
