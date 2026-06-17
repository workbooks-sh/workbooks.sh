defmodule Workbooks.WorkKits do
  @moduledoc """
  Toolkit discovery (L4, wb-11ck.46) — the agent extensibility surface. A toolkit
  makes an agent competent with a CLI it has never seen: a single `<work-ref rel="kit">`
  HTML element (the `manifest.html` front-door) names the CLI it wraps and indexes
  deep skill recipes (Markdown) the agent reads on demand.

  This module is the PUBLIC FACADE; the work is split by responsibility into
  siblings under `Workbooks.WorkKits.*`:

    * `Manifest` — HTML manifest parsing (Floki) + descriptor/requires/property readers.
    * `Registry` — on-disk discovery roots, toolkit dirs, skill paths, releases.
    * `Graph`    — the `<work-ref rel="needs">` dependency closure (in-doc + on-disk).
    * `Build`    — `work kit build`, inline self-authoring, promote, provenance/sign.
    * `Injection`— the Tier-1 TOOLKITS index + the discovered component catalog.

  The read surfaces that live here (discover/show/search/verify/eval) are the
  human/agent-facing rendering over those parts.

  ## TRUST BOUNDARY (wb-sec)

  The discovery root ($WB_WORKKITS_ROOT or ./toolkits) is an UNAUTHENTICATED,
  writable directory. A toolkit dropped there is UNTRUSTED supply-chain input —
  NOT "first-party" by virtue of its location. Accordingly:

    * READ-ONLY surfaces (list / show / search) are open, but slugs/roots are
      path-contained (no `..`/separator traversal) and $WB_WORKKITS_ROOT is honored
      only if it is an existing dir.
    * EXECUTION surfaces (`verify` pre blocks, `run` task blocks) are DISABLED
      (wb-9ja). Native execution is banned — `exec_allowed?` is always false and the
      :role-bash lane never shells out. Ship the toolkit's CLI as a WASM command.
    * BUILD (`build`) refuses to register a command under a reserved built-in name;
      compilers run under the sandbox (see PackageManager).

  See docs/TOOLKITS-V3.md for the full model.
  """
  alias Workbooks.WorkKits.{Build, Graph, Injection, Manifest, Registry}

  @manifest "manifest.html"
  @skill_ext ".md"

  # ── Discovery ──────────────────────────────────────────────────────────────

  @doc "Every `<work-ref rel=\"kit\">` self-declaration in a workbook's HTML — the discovery query."
  def discover(html) when is_binary(html) do
    html |> Manifest.work_toolkit_nodes() |> Enum.map(&Manifest.view/1)
  end

  @doc "Discover toolkits on disk (each `<root>/<name>/manifest.html`), tagging each view with its `:dir`."
  defdelegate discover_dir(root), to: Registry

  @doc "Skill names available in a toolkit dir (read the body on demand — progressive disclosure)."
  defdelegate skills(toolkit_dir), to: Registry

  @doc "Default discovery root: $WB_WORKKITS_ROOT (validated), else first of workkits/ | ../workkits."
  defdelegate default_root(), to: Registry

  @doc """
  Resolve a `<work-agent>`'s `kits` list → the toolkit views it may use, expanded
  over the dependency graph (transitive closure first, then flatten; dedup).
  """
  defdelegate resolve(html, agent_id), to: Graph

  @doc "Transitive closure of `roots` over toolkit-id dependency edges (a DAG; back-edge raises)."
  defdelegate closure(roots, edges, known), to: Graph

  @doc "Expand declared ids into the transitive closure over ON-DISK dependency edges."
  def closure_disk(ids, root \\ default_root()), do: Graph.closure_disk(ids, root)

  @doc """
  Resolve a toolkit by id and run its wrapped CLI as a registered WASM command —
  the vertical from L4 discovery to the L0 command leaf.
  """
  def run(html, toolkit_id, input) when is_binary(html) do
    case html |> discover() |> Enum.find(&(&1.id == toolkit_id)) do
      nil -> {:error, {:no_toolkit, toolkit_id}}
      %{cli: nil} -> {:error, {:no_cli, toolkit_id}}
      %{cli: cli} -> Workbooks.CommandRegistry.run(cli, input)
    end
  end

  # ── Descriptor / parsing (delegated to Manifest) ───────────────────────────

  @doc "Parse a toolkit's build descriptor from its `manifest.html` (by id)."
  def descriptor(id, root \\ default_root()) do
    case Registry.tk_dir(id, root) do
      nil -> {:error, {:no_toolkit, id}}
      dir -> {:ok, Manifest.parse_descriptor(File.read!(Path.join(dir, @manifest)))}
    end
  end

  @doc "Parse a manifest body (`<work-ref rel=\"kit\">` HTML) into the build descriptor."
  defdelegate parse_descriptor(body), to: Manifest

  @doc "Parse a raw `requires` value into typed `{:cli, tok} | {:dep, name, raw}` tokens."
  defdelegate parse_requires(line), to: Manifest

  @doc false
  defdelegate extract_role_blocks(content, role), to: Manifest

  # ── The `work kit` read surface ────────────────────────────────────────────

  @doc "`work kit list` — every toolkit under the root, keyed by id, with status + tagline."
  def list_text(root \\ default_root()) do
    case Registry.discover_dir(root) do
      [] ->
        "(no toolkits under #{root})"

      tks ->
        tks
        |> Enum.sort_by(& &1.id)
        |> Enum.map_join("\n", fn t ->
          "#{String.pad_trailing(t.id, 16)} #{String.pad_trailing(t.status || "-", 12)} #{Registry.manifest_kw(t.dir, "TAGLINE") || ""}"
        end)
    end
  end

  @doc "The compact TOOLKITS index injected into an agent's system prompt (Tier-1 progressive disclosure)."
  def injection_text(names, root \\ default_root()), do: Injection.injection_text(names, root)

  @doc "The component catalog injected when the resolved closure includes a `#+EXEC: component` toolkit."
  def component_catalog(names, root \\ default_root()), do: Injection.component_catalog(names, root)

  @doc "`work kit show <id>` — the manifest front door + the skill index."
  def show_text(id, root \\ default_root()) do
    case Registry.tk_dir(id, root) do
      nil ->
        "no such toolkit: #{id}"

      dir ->
        File.read!(Path.join(dir, @manifest)) <>
          "\n\nSkills (read with `work kit show #{id} <skill>`):\n" <>
          Enum.map_join(Registry.skills(dir), "\n", &("  " <> &1))
    end
  end

  @doc "`work kit show <id> <skill>` — a skill body, with a TOC header."
  def show_skill_text(id, slug, root \\ default_root()) do
    with dir when not is_nil(dir) <- Registry.tk_dir(id, root),
         path when not is_nil(path) <- Registry.skill_path(dir, slug) do
      body = File.read!(path)
      toc = Manifest.captions(body)
      head = if toc == [], do: "", else: "TOC (CAPTIONs):\n" <> Enum.map_join(toc, "\n", &("  • " <> &1)) <> "\n\n"
      head <> body
    else
      _ -> "no such skill: #{id}/#{slug}"
    end
  end

  @doc "`work kit search <q>` — substring match across all skills (path:line: text)."
  def search_text(query, root \\ default_root()) do
    q = String.downcase(query)
    base = Path.expand(root)

    hits =
      Path.wildcard(Path.join(root, "*/skills/**/*#{@skill_ext}"))
      # SECURITY (wb-sec, finding #6): only emit content for files that truly live
      # under the resolved root — a symlinked entry that escapes is skipped.
      |> Enum.filter(&Registry.contained?(&1, base))
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

  @doc "`work kit verify <id>` — structural checks (native :role pre blocks are DISABLED, wb-9ja)."
  def verify_text(id, root \\ default_root()) do
    case Registry.tk_dir(id, root) do
      nil ->
        "no such toolkit: #{id}"

      dir ->
        d = Manifest.parse_descriptor(File.read!(Path.join(dir, @manifest)))

        struct =
          [
            {File.exists?(Path.join(dir, @manifest)), "#{@manifest} present"},
            {File.exists?(Path.join([dir, "skills", "overview#{@skill_ext}"])), "skills/overview#{@skill_ext} present"}
          ] ++ exec_checks(d) ++ cap_checks(d) ++ Build.trust_checks(dir, d)

        # :role pre blocks are arbitrary NATIVE bash. Native execution is banned
        # (wb-9ja), so verify never runs them — the structural checks above are the
        # gate; any pre blocks are reported as disabled (not skipped-pending-flag).
        n = pre_block_count(dir)
        pre = if n == 0, do: [], else: [{true, "pre checks DISABLED (#{n} block(s); native :role bash execution removed — wb-9ja)"}]

        Enum.map_join(struct ++ pre, "\n", fn {ok, label} -> "#{if ok, do: "✓", else: "✗"} #{label}" end)
    end
  end

  @doc """
  `work kit eval <id>` — run the toolkit's bundled eval suite. Each `evals/*.md`
  case is Tier 2 (agent + judge, needs an LLM key) when it declares TASK; Tier 1
  (deterministic :role-bash) is DISABLED (native exec banned — wb-9ja). See EVALS.md.
  """
  def eval_text(id, root \\ default_root(), filter \\ nil, model \\ nil) do
    case Registry.tk_dir(id, root) do
      nil ->
        "no such toolkit: #{id}"

      dir ->
        cases =
          Path.wildcard(Path.join([dir, "evals", "*.md"]))
          |> Enum.filter(&Registry.contained?(&1, Path.expand(dir)))
          # `filter` (a substring of the eval filename) runs just ONE case.
          |> Enum.filter(&(is_nil(filter) or String.contains?(Path.basename(&1), filter)))
          |> Enum.sort()

        if cases == [] do
          if filter,
            do: "#{id}: no eval matches #{inspect(filter)}",
            else: "#{id}: no eval suite (add evals/*.md — see toolkits/EVALS.md)"
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

  # Each evals/*.md is one case: Tier 2 (agent + judge) if it declares TASK,
  # else Tier 1 (deterministic eval-role block + EXPECT). Returns {:pass|:fail|:skip, label}.
  defp run_eval_case(path, dir, id, model) do
    text = File.read!(path)
    name = Path.relative_to(path, dir)

    cond do
      Manifest.prop(text, "TASK") != nil -> agent_judge_case(text, name, dir, id, model)
      Manifest.extract_role_blocks(text, "eval") != [] -> deterministic_case(name)
      true -> {:fail, "#{name}: no eval-role block and no TASK"}
    end
  end

  # Tier 1 — deterministic :role eval blocks ran NATIVE bash. Native execution is
  # banned (wb-9ja), so this tier can no longer run; report it disabled.
  defp deterministic_case(name),
    do: {:skip, "#{name}: DISABLED (native :role bash eval removed — wb-9ja)"}

  # Tier 2 — run an agent on :TASK: (the toolkit's overview injected so it knows
  # the surface), then a judge model scores the result + tool trace vs :RUBRIC:.
  defp agent_judge_case(text, name, dir, id, model) do
    task = Manifest.prop(text, "TASK")
    rubric = Manifest.prop(text, "RUBRIC") || "The result correctly and completely satisfies the task."
    exec? = Manifest.prop(text, "EXEC") in ["true", "yes", "1"]
    # MAX_STEPS is a high SAFETY-NET (runaway guard), NOT a binding cap — an eval
    # must let the agent WORK THE PROBLEM to completion and MEASURE how it solved it.
    max = case Integer.parse(Manifest.prop(text, "MAX_STEPS") || "40") do
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
          (Manifest.prop(text, "SYSTEM") ||
             "You are an agent being evaluated. Use the #{id} toolkit to complete the task; state your final result clearly.") <>
            overview

        run =
          Workbooks.Agent.run(system, task,
            model: model || System.get_env("WB_EVAL_MODEL"),
            max_steps: max,
            exec: exec?,
            tenant: "eval"
          )

        # Telemetry from the run's tool trace. `steps` = LLM TURNS; `commands` =
        # actual tool CALLS — a rubric that wants "ran >= 2 commands" must read
        # `commands`, NOT `steps` (a batching agent shows steps:1).
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

  defp llm_key?,
    do:
      Workbooks.Secrets.get("OPENROUTER_API_KEY") not in [nil, ""] or
        System.get_env("WB_LLM_KEY") not in [nil, ""]

  # ── verify check helpers ───────────────────────────────────────────────────

  # Count :role pre blocks across a toolkit's skills (for the verify SKIPPED note).
  defp pre_block_count(dir) do
    Path.wildcard(Path.join([dir, "skills", "**", "*#{@skill_ext}"]))
    |> Enum.filter(&Registry.contained?(&1, Path.expand(dir)))
    |> Enum.reduce(0, fn path, acc -> acc + length(Manifest.extract_role_blocks(File.read!(path), "pre")) end)
  end

  # wb-pkh.6: every declared cap must be GRANTABLE (known to Policy), and at least
  # one profile must grant the WHOLE declared set, else the toolkit can never
  # instantiate. Also report the minimal granting profile(s).
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
      buildable? -> [{true, "exec: command — #{bin} not yet registered, build descriptor present (run `work kit build`)"}]
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

  defp exec_checks(%{exec: "task"}), do: [{true, "exec: task (recipes run via `work kit run`)"}]
  defp exec_checks(%{exec: "federation"}), do: [{true, "exec: federation (data-source/sync faces)"}]

  defp exec_checks(%{exec: "kernel", cli_bin: bin}) do
    if is_binary(bin) and bin in Workbooks.KernelRegistry.list(),
      do: [{true, "exec: kernel — #{bin} registered (open via Workbooks.Kernel / Fabric.map_kernel)"}],
      else: [{true, "exec: kernel — #{bin} not yet built (run `work kit build`)"}]
  end

  defp exec_checks(%{exec: "component"}),
    do: [{true, "exec: component (WIT-typed; built via build_dir, run in-VM via Instance)"}]

  defp exec_checks(%{exec: other}), do: [{false, "exec: unknown mode #{inspect(other)}"}]

  @doc "Whether :role bash execution is opted-in. DISABLED (wb-9ja): always false — native exec is banned."
  def exec_allowed?, do: false

  @doc """
  `work kit run <id> <task> -- <args...>` — DISABLED (wb-9ja). A `:role task` block
  is arbitrary NATIVE bash; native execution is banned, and this surface is reachable
  by the in-sandbox agent (its `work` tool). The toolkit's CLI is meant to ship as a
  WASM command (the Dock-gated `run-command` path) — convert it and invoke that.
  """
  def run_task_text(id, task, args, root \\ default_root()) do
    # If the toolkit ships no compiled command (CLI_BIN: work), its skills document
    # built-in `work` verbs — so `toolkit run` was never the right path. Guide the
    # agent to the DIRECT invocation rather than a cryptic refusal.
    case Registry.tk_dir(id, root) do
      nil ->
        "no such toolkit: #{id}"

      dir ->
        d = Manifest.parse_descriptor(File.read!(Path.join(dir, @manifest)))

        if d.cli_bin == "work" do
          suggested = String.trim("work #{task} " <> Enum.join(List.wrap(args), " "))

          "#{id} is a direct-verb toolkit — its skills document built-in `work` verbs, " <>
            "not a runnable command. Run it DIRECTLY through your `work` tool: `#{suggested}` " <>
            "(don't use `work kit run` for #{id})."
        else
          "refusing to run #{id}/#{task}: native :role bash execution removed (wb-9ja). " <>
            "Ship the toolkit CLI as a WASM command and run it via the Dock-gated run-command path."
        end
    end
  end

  # ── Build / promote / provenance (delegated to Build) ──────────────────────

  @doc "`work kit build <id> [<which>]` — the declarative auto-wrap (materialize the CLI as a WASM command)."
  def build_text(id, root \\ default_root()), do: Build.build_text(id, root)
  def build_text(id, which, root), do: Build.build_text(id, which, root)

  @doc "Inline self-authoring: build + register a command directly from a source file."
  defdelegate build_inline_text(name, lang, file), to: Build

  @doc "PROMOTE a session command to a durable workspace toolkit (session → workspace → registry)."
  defdelegate promote_text(name, lang, src_file, opts \\ []), to: Build

  @doc "Sign a toolkit's manifest as `tenant` (writes AUTHOR_DID + SIGNATURE)."
  def sign_text(id, tenant, root \\ default_root()), do: Build.sign_text(id, tenant, root)

  @doc "Verify a manifest's provenance: {:ok, did} | {:error, reason}."
  defdelegate manifest_provenance(dir), to: Build

  # ── Versioned releases (delegated to Registry) ─────────────────────────────

  @doc "`work kit versions <id>` — available versions/tags (releases.json ∪ manifest VERSION)."
  def versions_text(id, root \\ default_root()), do: Registry.versions_text(id, root)

  @doc "`work kit live [<id>]` — the currently-live version (one toolkit, or every toolkit's pin)."
  def live_text(id_or_root \\ nil, root \\ default_root()), do: Registry.live_text(id_or_root, root)

  @doc "`work kit rollback <id> <version>` — set the live version back to an older release."
  def rollback_text(id, version, root \\ default_root()), do: Registry.rollback_text(id, version, root)
end
