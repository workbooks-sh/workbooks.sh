defmodule Workbooks.Toolkits do
  @moduledoc """
  Toolkit discovery (L4, wb-11ck.46) — the agent extensibility surface. A toolkit
  makes an agent competent with a CLI it has never seen: a `:toolkit:`-tagged Org
  node (the manifest front-door) names the CLI it wraps and indexes deep skill
  recipes the agent reads on demand. This module is the *discovery* half — the
  canonical concept, recreated on the kernel's existing tag/property extraction,
  not a port of the mainline layout.

  Discovery is one query — `(tags :toolkit:)` over the Context Tree. An `:agent:`
  node's `:TOOLKITS:` property lists the toolkits it may use; each name resolves
  to a `:toolkit:` node. No tool-search subsystem: org + the kernel. The skill
  bodies are read lazily (the agent `cat`s the skill file when a task routes to
  it); the runtime only resolves *which* toolkit, never inlines the manual.

  In the clean-room a toolkit's CLI is a WASM command (`run-command`,
  wb-11ck.21), not a native PATH binary — but the discovery contract is identical.
  """
  alias Workbooks.OQL

  @doc "Every `:toolkit:` node in a Context Tree — the `(tags :toolkit:)` query."
  def discover(org) when is_binary(org) do
    org |> OQL.parse_headlines() |> Enum.filter(&toolkit?/1) |> Enum.map(&view/1)
  end

  @doc """
  Discover toolkits on disk: read every `<root>/<name>/manifest.org`, run the same
  `(tags :toolkit:)` query over each, and tag the view with its directory so the
  agent can `cat` a skill on demand. This is the canonical filesystem-native
  shape — a toolkit is a directory; discovery is org + the kernel, no new infra.
  """
  def discover_dir(root) do
    Path.wildcard(Path.join(root, "*/manifest.org"))
    |> Enum.flat_map(fn manifest ->
      dir = Path.dirname(manifest)
      manifest |> File.read!() |> discover() |> Enum.map(&Map.put(&1, :dir, dir))
    end)
  end

  @doc "Skill names available in a toolkit dir (read the body on demand — progressive disclosure)."
  def skills(toolkit_dir) do
    Path.wildcard(Path.join([toolkit_dir, "skills", "*.org"]))
    |> Enum.map(&Path.basename(&1, ".org"))
    |> Enum.sort()
  end

  @doc """
  Resolve an `:agent:` node's `:TOOLKITS:` list → the toolkit nodes it may use,
  in declared order. Unknown names are dropped (a missing toolkit is not a crash).
  """
  def resolve(org, agent_id) when is_binary(org) do
    hs = OQL.parse_headlines(org)
    wanted = hs |> agent(agent_id) |> names()
    by_id = hs |> Enum.filter(&toolkit?/1) |> Map.new(&{&1["id"], view(&1)})
    wanted |> Enum.map(&by_id[&1]) |> Enum.reject(&is_nil/1)
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

  @doc "Default discovery root: $WB_TOOLKITS_ROOT, else first of toolkits/ | ../toolkits that exists."
  def default_root do
    System.get_env("WB_TOOLKITS_ROOT") ||
      Enum.find(["toolkits", "../toolkits", Path.expand("../toolkits", File.cwd!())], &File.dir?/1) ||
      "toolkits"
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

  @doc "`wb toolkit show <id>` — the manifest front door + the skill index."
  def show_text(id, root \\ default_root()) do
    case tk_dir(id, root) do
      nil ->
        "no such toolkit: #{id}"

      dir ->
        File.read!(Path.join(dir, "manifest.org")) <>
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

    hits =
      Path.wildcard(Path.join(root, "*/skills/**/*.org"))
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
        d = parse_descriptor(File.read!(Path.join(dir, "manifest.org")))

        struct =
          [
            {File.exists?(Path.join(dir, "manifest.org")), "manifest.org present"},
            {File.exists?(Path.join([dir, "skills", "overview.org"])), "skills/overview.org present"}
          ] ++ exec_checks(d)

        pre =
          Path.wildcard(Path.join([dir, "skills", "**", "*.org"]))
          |> Enum.flat_map(fn path ->
            extract_role_blocks(File.read!(path), "pre")
            |> Enum.map(fn body ->
              {out, code} = run_bash(body, [])
              {code == 0, "pre #{Path.relative_to(path, dir)}" <> if(code == 0, do: "", else: ": " <> String.trim(out))}
            end)
          end)

        Enum.map_join(struct ++ pre, "\n", fn {ok, label} -> "#{if ok, do: "✓", else: "✗"} #{label}" end)
    end
  end

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
  Parse a toolkit's build descriptor from its `manifest.org`. Returns a map with
  `:exec`, `:build_src` (a `{:crate|:git|:path, value}` tuple or nil), `:build_lang`,
  `:caps` (list), `:cli_bin`, and `:arg_mode`. Missing keys are nil/[]. The
  descriptor is what `wb toolkit build`/`verify` act on.
  """
  def descriptor(id, root \\ default_root()) do
    case tk_dir(id, root) do
      nil -> {:error, {:no_toolkit, id}}
      dir -> {:ok, parse_descriptor(File.read!(Path.join(dir, "manifest.org")))}
    end
  end

  @doc false
  def parse_descriptor(body) do
    %{
      exec: kw(body, "EXEC"),
      build_src: parse_build_src(kw(body, "BUILD_SRC")),
      build_lang: kw(body, "BUILD_LANG"),
      caps: (kw(body, "CAPS") || "") |> String.split() ,
      cli_bin: kw(body, "CLI_BIN") || drawer(body, "CLI_BIN"),
      arg_mode: arg_mode(kw(body, "ARG_MODE"))
    }
  end

  # crate:<name> | git+<url> | path:<dir>  → tagged tuple (nil if absent/unknown).
  defp parse_build_src(nil), do: nil

  defp parse_build_src(spec) do
    spec = String.trim(spec)

    cond do
      String.starts_with?(spec, "crate:") -> {:crate, String.trim_leading(spec, "crate:")}
      String.starts_with?(spec, "git+") -> {:git, String.trim_leading(spec, "git+")}
      String.starts_with?(spec, "path:") -> {:path, String.trim_leading(spec, "path:")}
      true -> {:unknown, spec}
    end
  end

  defp arg_mode("stdin1"), do: :stdin1
  defp arg_mode("argv"), do: :argv
  defp arg_mode(_), do: :argv

  # `#+KEY: value` keyword (file-level). nil if absent or empty. The value capture
  # is restricted to the SAME line ([^\n]) — `\s*` would otherwise cross blank
  # lines and grab the next non-empty line.
  defp kw(body, key) do
    case Regex.run(~r/^#\+#{key}:[^\S\n]*([^\n]*)$/m, body) do
      [_, v] -> blank_to_nil(String.trim(v))
      _ -> nil
    end
  end

  # `:KEY: value` from a :PROPERTIES: drawer. nil if absent or empty.
  defp drawer(body, key) do
    case Regex.run(~r/^[^\S\n]*:#{key}:[^\S\n]*([^\n]*)$/m, body) do
      [_, v] -> blank_to_nil(String.trim(v))
      _ -> nil
    end
  end

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
  def build_text(id, root \\ default_root()) do
    with {:ok, d} <- descriptor(id, root) do
      do_build(id, d)
    else
      {:error, {:no_toolkit, _}} -> "no such toolkit: #{id}"
    end
  end

  defp do_build(id, %{cli_bin: nil}),
    do: "cannot build #{id}: no CLI_BIN declared (nothing to register a command under)"

  defp do_build(id, %{exec: exec}) when exec in ["task", "federation"],
    do: "#{id}: #+EXEC: #{exec} — no command to build (task/federation toolkits ship no CLI binary)"

  defp do_build(id, %{exec: "posix", cli_bin: bin}) do
    case System.find_executable(bin) do
      nil -> "#{id}: #+EXEC: posix — native binary #{inspect(bin)} not found on PATH (install it; nothing to build)"
      path -> "#{id}: #+EXEC: posix — native binary #{bin} present at #{path} (no WASM build needed)"
    end
  end

  defp do_build(id, %{exec: exec, build_src: {:crate, crate}, cli_bin: bin, arg_mode: mode})
       when exec in ["command", nil] do
    case Workbooks.CommandRegistry.build_and_register_crate(bin, crate, mode) do
      {:ok, wasm} -> "#{id}: built crate #{crate} → #{wasm}; registered command #{inspect(bin)} (mode #{mode})"
      {:error, reason} -> "#{id}: build FAILED for crate #{crate}:\n" <> error_text(reason)
    end
  end

  defp do_build(id, %{exec: exec, build_src: {:path, dir}, build_lang: lang, cli_bin: bin, arg_mode: mode})
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

  defp do_build(id, %{build_src: nil}),
    do: "#{id}: no #+BUILD_SRC declared — nothing to build (declare crate:<name> | path:<dir>)"

  defp do_build(id, %{build_src: {:git, url}}),
    do: "#{id}: #+BUILD_SRC git+#{url} not yet supported by `wb toolkit build` (use crate: or path:)"

  defp do_build(id, %{build_src: {:unknown, spec}}),
    do: "#{id}: unrecognized #+BUILD_SRC #{inspect(spec)} (expected crate:<name> | git+<url> | path:<dir>)"

  defp error_text(reason) when is_binary(reason), do: String.slice(reason, -2000, 2000)
  defp error_text(reason), do: inspect(reason)

  @doc """
  `wb toolkit run <id> <task> -- <args...>` — extract the `:role task` bash block
  from the `<task>` skill and run it with positional `$1 $2 …` from <args>.
  """
  def run_task_text(id, task, args, root \\ default_root()) do
    with dir when not is_nil(dir) <- tk_dir(id, root),
         path when not is_nil(path) <- skill_path(dir, task),
         [body | _] <- extract_role_blocks(File.read!(path), "task") do
      {out, _code} = run_bash(body, args)
      out
    else
      [] -> "no :role task block in #{id}/#{task}"
      _ -> "no such toolkit/skill: #{id}/#{task}"
    end
  end

  # Is the declared #+EXEC mode satisfiable right now?
  #   command  → CLI_BIN already a registered command, OR a #+BUILD_SRC that can
  #              produce it (so `wb toolkit build` would satisfy it).
  #   posix    → CLI_BIN resolves on PATH.
  #   task     → at least one skill carries a :role task block.
  #   federation → a plugin/ data-source face exists.
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
  defp exec_checks(%{exec: other}), do: [{false, "exec: unknown mode #{inspect(other)}"}]

  defp tk_dir(id, root) do
    case Enum.find(discover_dir(root), &(&1.id == id)) do
      %{dir: dir} -> dir
      _ -> nil
    end
  end

  # thin skill: skills/<slug>.org ; thick skill: skills/<slug>/SKILL.org
  defp skill_path(dir, slug) do
    thin = Path.join([dir, "skills", "#{slug}.org"])
    thick = Path.join([dir, "skills", slug, "SKILL.org"])

    cond do
      File.exists?(thin) -> thin
      File.exists?(thick) -> thick
      true -> nil
    end
  end

  defp manifest_kw(dir, key) do
    with {:ok, body} <- File.read(Path.join(dir, "manifest.org")),
         [_, v] <- Regex.run(~r/^#\+#{key}:\s*(.+)$/m, body) do
      String.trim(v)
    else
      _ -> nil
    end
  end

  defp captions(body),
    do: Regex.scan(~r/^#\+CAPTION:\s*(.+)$/m, body) |> Enum.map(fn [_, c] -> String.trim(c) end)

  @doc false
  # Extract the body of every `#+begin_src bash :role <role> …` block.
  def extract_role_blocks(content, role) do
    ~r/#\+begin_src\s+[^\n]*:role\s+#{role}\b[^\n]*\n(.*?)\n\s*#\+end_src/s
    |> Regex.scan(content)
    |> Enum.map(fn [_, body] -> body end)
  end

  # Run a bash snippet with positional args ($1, $2, …). Trusted input: toolkit
  # skill files are first-party, not user-submitted.
  defp run_bash(body, args), do: System.cmd("bash", ["-c", body, "bash"] ++ args, stderr_to_stdout: true)

  defp agent(hs, id), do: Enum.find(hs, &("agent" in &1["tags"] and &1["id"] == id))

  defp names(nil), do: []
  defp names(agent), do: (agent["props"]["TOOLKITS"] || "") |> String.split()

  defp toolkit?(h), do: "toolkit" in h["tags"]

  defp view(h) do
    %{
      id: h["id"],
      title: h["title"],
      cli: h["props"]["CLI_BIN"],
      status: h["props"]["STATUS"],
      skill_dir: h["props"]["SKILL_DIR"]
    }
  end
end
