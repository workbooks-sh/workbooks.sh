defmodule Workbooks.BrandBook do
  @moduledoc """
  The brandnana brand book, ported onto the clean-room runtime. The mainline runs
  this as a Scout→Strategist→Designer board; here it's a three-stage pipeline over
  one shared OS workdir, driven by the clean-room agent loop:

    1. HARVEST  — `brandnana harvest-all <domain>` (deterministic sweep → a
       queryable substrate in the workdir). Needs the cloud keys, so it only fully
       runs on a deployed engine.
    2. STRATEGIST — the real brandnana-strategist agent (exec + workdir) reads the
       substrate, writes gated analysis files.
    3. DESIGNER — the real designer agent composes + publishes the deck-v2 HTML.

  The agents are the canonical profile `<work-agent>` HTML defs baked at
  WB_PROFILE_DIR (/opt/profile/agents) — the exact files the production engine uses
  — parsed by `Workbooks.AgentDef`; their bash/brandnana toolkits are the
  clean-room `run` exec tool. The engine env (the brandnana keys) is inherited by
  every `run`. Stage status is written to `<workdir>/_status.json` for
  observability.
  """
  alias Workbooks.AgentDef

  @doc "Run the full brand-book pipeline for `domain`. Returns %{domain, workdir, stages, deck}."
  def run(domain, opts \\ []) do
    workdir = opts[:workdir] || Path.join(System.tmp_dir!(), "brandbook-#{slug(domain)}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workdir)

    status(workdir, %{domain: domain, stage: "harvest", started: true})
    harvest = harvest(domain, workdir)

    status(workdir, %{domain: domain, stage: "strategist", harvest: harvest})
    strategist = stage(strategist_path(), strategist_task(domain), workdir, opts[:strategist_steps] || 75)

    status(workdir, %{domain: domain, stage: "designer", harvest: harvest})
    designer = stage(designer_path(), designer_task(domain), workdir, opts[:designer_steps] || 120)

    result = %{
      domain: domain,
      workdir: workdir,
      harvest: harvest,
      strategist: String.slice(strategist.result, 0, 400),
      designer: String.slice(designer.result, 0, 400),
      deck: find_deck(workdir),
      published: published_url(workdir)
    }

    status(workdir, Map.put(result, :stage, "done"))
    result
  end

  # Stage 1 — the deterministic harvest (inherits the engine env / keys).
  defp harvest(domain, workdir) do
    {out, code} = System.cmd("brandnana", ["harvest-all", domain], cd: workdir, stderr_to_stdout: true)
    %{exit: code, tail: String.slice(out, max(byte_size(out) - 400, 0), 400)}
  rescue
    e -> %{exit: :error, error: Exception.message(e)}
  end

  # A stage gets a hard wall-clock budget: an agent can wedge (a stalled LLM call
  # past its own timeout, a slow tool) and `max_steps` only bounds step COUNT, not
  # time. If the stage exceeds this, kill it and return a partial — the pipeline
  # proceeds (the next stage / find_deck still sees whatever landed on disk).
  @stage_timeout_ms 15 * 60 * 1000

  # Stages 2 & 3 — a real brandnana agent, exec-enabled, rooted in the workdir.
  # on_step appends each tool step to a trace file so a long-horizon run is
  # observable from outside (the in-VFS events.html is only written at finish).
  defp stage(agent_def_path, task, workdir, steps) do
    role = Path.basename(agent_def_path, ".html")
    trace = Path.join(workdir, "_trace-#{role}.jsonl")
    on_step = fn ev ->
      line = Jason.encode!(%{step: ev.step, tool: ev.tool, out: String.slice(ev.output || "", 0, 160)})
      File.write(trace, line <> "\n", [:append])
    end

    t = Task.async(fn ->
      AgentDef.run(File.read!(agent_def_path), task, exec: true, workdir: workdir, max_steps: steps, on_step: on_step)
    end)

    case Task.yield(t, @stage_timeout_ms) || Task.shutdown(t, :brutal_kill) do
      {:ok, result} -> result
      _ -> %{result: "#{role}: stage timed out (#{div(@stage_timeout_ms, 60_000)}m wall-clock)", steps: 0, events: []}
    end
  end

  defp strategist_task(domain) do
    "You are Stage-2 (strategist) for #{domain}. The harvest substrate is in your " <>
      "working directory: brand.org, catalog/, social/, ads.org, plus pre-read " <>
      "summaries in analysis/reports/. \n\n" <>
      "READ BUDGET — this is a HARD rule, not advice: read ONLY the five " <>
      "analysis/reports/*.org pre-reads (brand, catalog, social, reviews, ads) " <>
      "plus brand.org. They already summarize everything. DO NOT cat catalog/ " <>
      "product files and DO NOT run jq on social/*.json — those JSON files are " <>
      "large and often malformed (jq will error on nulls); the social pre-read " <>
      "already has what you need. Every step spent reading raw catalog/social is " <>
      "wasted and risks running out of budget before you write.\n\n" <>
      "By step 8 at the latest, WRITE all four gated analyses as RELATIVE paths: " <>
      "analysis/positioning.org, analysis/audience.org, analysis/messaging.org, " <>
      "analysis/voice.org — each an :insight: grounded in the pre-reads' :point: " <>
      "facts via :GROUNDS:. Then run `brandnana analysis check .` and fix any FAIL " <>
      "until it prints RESULT: PASS. Then finish with done."
  end

  defp designer_task(domain) do
    "You are Stage-3 (designer) for #{domain}. The substrate + the gated " <>
      "analysis/*.org are in your working directory. Build a LONG, COHERENT " <>
      "reveal.js presentation — aim for 25+ slides with a clear arc: splash, act " <>
      "dividers, positioning, audience personas, the catalog ladder, ad concepts, " <>
      "voice, palette, an end-card. Get the spine with `brandnana book " <>
      "insight-slides .`, author one slide spec per file under spec/ (relative " <>
      "paths), assemble with `brandnana book assemble spec --out deck.html`. Then " <>
      "make it a QUERYABLE context repository: `brandnana book seal deck.html .` " <>
      "(embeds the org substrate + catalog SQLite as the wb-source-bundle), verify " <>
      "`grep -c 'id=\"wb-source-bundle\"' deck.html` prints 1, then `brandnana book " <>
      "publish <slug> deck.html`. Write the published URL to ./published-url. " <>
      "Review the rendered slides for overflow/empties and fix them. Finish with done."
  end

  # Agent defs: the canonical profile agents (baked at WB_PROFILE_DIR), with a
  # local examples/ fallback for dev.
  defp strategist_path, do: first_existing(["#{profile_dir()}/agents/brandnana-strategist.html", local("bn-strategist.html")])
  defp designer_path, do: first_existing(["#{profile_dir()}/agents/designer.html", local("bn-designer.html")])
  defp profile_dir, do: System.get_env("WB_PROFILE_DIR") || "/opt/profile"
  defp local(name), do: Path.expand(Path.join([__DIR__, "..", "examples", "agents", name]))
  defp first_existing(paths), do: Enum.find(paths, &File.exists?/1) || hd(paths)

  defp find_deck(workdir) do
    Path.wildcard(Path.join(workdir, "**/deck*.html")) |> List.first() ||
      Path.wildcard(Path.join(workdir, "**/*.html")) |> List.first()
  end

  defp published_url(workdir) do
    case File.read(Path.join(workdir, "published-url")) do
      {:ok, url} -> String.trim(url)
      _ -> nil
    end
  end

  defp status(workdir, map), do: File.write(Path.join(workdir, "_status.json"), Jason.encode!(map))
  defp slug(d), do: String.replace(d, ~r/[^a-z0-9]/i, "-")
end
