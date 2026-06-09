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

  ## TRUST BOUNDARY (wb-sec)

  The discovery root ($WB_TOOLKITS_ROOT or ./toolkits) is an UNAUTHENTICATED,
  writable directory. A toolkit dropped there is UNTRUSTED supply-chain input —
  NOT "first-party" by virtue of its location. Accordingly:

    * READ-ONLY surfaces (list / show / search) are open, but slugs/roots are
      path-contained (no `..`/separator traversal; files must resolve inside the
      toolkit) and $WB_TOOLKITS_ROOT is honored only if it is an existing dir.
    * EXECUTION surfaces (`verify` pre blocks, `run` task blocks) are DEFAULT-DENY.
      A :role bash block is arbitrary host code; it runs ONLY when the operator
      opts in via `WB_TOOLKIT_EXEC=1`, and even then it runs under
      `Workbooks.Sandbox` (network-denied, fs-confined) with a wall-clock cap and
      a `ulimit` prologue (anti fork-bomb), never bare host bash.
    * BUILD (`build`) refuses to register a command under a reserved built-in
      name (jq/grep/upper); compilers run under the sandbox (see PackageManager).

  The intended sandboxed surface for a toolkit's CLI is the WASM `run-command`
  path (Dock-gated). Host bash from skill files bypasses that and is therefore
  gated/capped/isolated above. See docs/TOOLKITS-V3.org for the full model.
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

    base = Path.expand(root)

    hits =
      Path.wildcard(Path.join(root, "*/skills/**/*.org"))
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
        d = parse_descriptor(File.read!(Path.join(dir, "manifest.org")))

        struct =
          [
            {File.exists?(Path.join(dir, "manifest.org")), "manifest.org present"},
            {File.exists?(Path.join([dir, "skills", "overview.org"])), "skills/overview.org present"}
          ] ++ exec_checks(d) ++ cap_checks(d)

        # SECURITY (wb-sec): :role pre blocks are arbitrary bash from an untrusted
        # toolkit dir. They run ONLY when execution is opted-in (WB_TOOLKIT_EXEC=1);
        # otherwise verify reports them as skipped (structural checks still run).
        pre =
          if exec_allowed?() do
            Path.wildcard(Path.join([dir, "skills", "**", "*.org"]))
            |> Enum.filter(&contained?(&1, Path.expand(dir)))
            |> Enum.flat_map(fn path ->
              extract_role_blocks(File.read!(path), "pre")
              |> Enum.map(fn body ->
                {out, code} = run_bash(body, [])
                {code == 0, "pre #{Path.relative_to(path, dir)}" <> if(code == 0, do: "", else: ": " <> String.trim(out))}
              end)
            end)
          else
            n = pre_block_count(dir)
            if n == 0, do: [], else: [{true, "pre checks SKIPPED (#{n} block(s); set WB_TOOLKIT_EXEC=1 to run sandboxed)"}]
          end

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
      arg_mode: arg_mode(kw(body, "ARG_MODE")),
      sha256: kw(body, "SHA256"),
      wasm_path: kw(body, "WASM_PATH"),
      preopen: kw(body, "PREOPEN")
    }
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

        cond do
          entries == [] ->
            do_build(id, parse_descriptor(File.read!(Path.join(dir, "manifest.org"))))

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
        File.write!(Path.join(dir, "skills/overview.org"), promote_skill(name))
        File.write!(Path.join(dir, "manifest.org"), promote_manifest(name, lang, build_src, tagline))

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
    #+TITLE: #{name} toolkit
    #+TOOLKIT: #{name}
    #+VERSION: 0.1.0
    #+STATUS: experimental
    #+TAGLINE: #{tagline}
    #+EXEC: command
    #+TRUST: first-party
    #+CLI_BIN: #{name}
    #+BUILD_LANG: #{lang}
    #+BUILD_SRC: path:#{build_src}
    #+ARG_MODE: argv

    * #{name} :toolkit:
    :PROPERTIES:
    :ID: #{name}
    :CLI_BIN: #{name}
    :END:
    Promoted from a session command (wb-rhs.6). Source-owned + rebuildable.

    | need   | skill    |
    |--------+----------|
    | use it | overview |
    """
  end

  defp promote_skill(name) do
    """
    #+TITLE: #{name} — overview

    * When to use this
    A command promoted from a session. NOT for anything else yet — extend the
    skill as the toolkit grows.

    * Workflow
    Run it through the Dock: =run-command #{name}= (argv + stdin → stdout).

    * Verification checklist
    - [ ] =wb toolkit build #{name}= registers the command
    - [ ] =run-command #{name}= produces expected output
    """
  end

  # A runtime entry is either runtimes/<name>.org (a flat pinned spec) or
  # runtimes/<name>/manifest.org (a dir carrying a build script + assets).
  defp runtime_entries(dir) do
    flat =
      Path.wildcard(Path.join([dir, "runtimes", "*.org"]))
      |> Enum.map(fn f -> {Path.basename(f, ".org"), f} end)

    sub =
      Path.wildcard(Path.join([dir, "runtimes", "*", "manifest.org"]))
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
    if bin in Workbooks.CommandRegistry.reserved_names(),
      do: "cannot build #{id}: CLI_BIN #{inspect(bin)} is a reserved built-in command name (refusing to shadow it)",
      else: do_build_clause(id, d)
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

  defp do_build_clause(id, %{exec: exec, build_src: {:crate, crate}, cli_bin: bin, arg_mode: mode})
       when exec in ["command", nil] do
    case Workbooks.CommandRegistry.build_and_register_crate(bin, crate, mode) do
      {:ok, wasm} -> "#{id}: built crate #{crate} → #{wasm}; registered command #{inspect(bin)} (mode #{mode})"
      {:error, reason} -> "#{id}: build FAILED for crate #{crate}:\n" <> error_text(reason)
    end
  end

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

  # gobuild:<pkg> — build a Go package to wasip1 (e.g. a Go interpreter like yaegi)
  # and register it so untrusted .go source runs in the sandbox.
  defp do_build_clause(id, %{exec: exec, build_src: {:gobuild, pkg}, cli_bin: bin, arg_mode: mode})
       when exec in ["command", nil] do
    case Workbooks.CommandRegistry.build_and_register_go(bin, pkg, mode) do
      {:ok, wasm} -> "#{id}: built go #{pkg} → #{wasm}; registered command #{inspect(bin)} (mode #{mode})"
      {:error, reason} -> "#{id}: build FAILED for go #{pkg}:\n" <> error_text(reason)
    end
  end

  # zigbuild:<file.zig> — compile a Zig source file (in the runtime's dir) to a
  # wasm32-wasi command with native zig. Zig = compile-to-wasm authoring (no interpreter).
  defp do_build_clause(id, %{exec: exec, build_src: {:zigbuild, rel}, cli_bin: bin, arg_mode: mode, src_dir: sdir})
       when exec in ["command", nil] do
    zfile = Path.join(sdir, rel)

    if not File.regular?(zfile) do
      "#{id}: zig source not found: #{zfile}"
    else
      case Workbooks.CommandRegistry.build_and_register_zig(bin, zfile, mode) do
        {:ok, wasm} -> "#{id}: compiled zig #{rel} → #{wasm}; registered command #{inspect(bin)} (mode #{mode})"
        {:error, reason} -> "#{id}: zig build FAILED for #{rel}:\n" <> error_text(reason)
      end
    end
  end

  # script:<file> — run a build script (in the runtime's own dir) that compiles a
  # language from source (e.g. Lua via wasi-sdk) and prints the output wasm path as
  # its LAST stdout line; we content-address + register it. For build-from-source
  # runtimes with no prebuilt (Lua, Zig).
  defp do_build_clause(id, %{exec: exec, build_src: {:script, rel}, cli_bin: bin, arg_mode: mode, src_dir: sdir})
       when exec in ["command", nil] do
    script = Path.join(sdir, rel)

    if not File.regular?(script) do
      "#{id}: build script not found: #{script}"
    else
      case Workbooks.CommandRegistry.build_and_register_script(bin, script, mode) do
        {:ok, wasm} -> "#{id}: ran build script #{rel} → #{wasm}; registered command #{inspect(bin)} (mode #{mode})"
        {:error, reason} -> "#{id}: build script FAILED for #{rel}:\n" <> error_text(reason)
      end
    end
  end

  defp do_build_clause(id, %{build_src: nil}),
    do: "#{id}: no #+BUILD_SRC declared — nothing to build (declare crate:<name> | path:<dir> | wasm:<url> | archive:<url>)"

  defp do_build_clause(id, %{build_src: {:git, url}}),
    do: "#{id}: #+BUILD_SRC git+#{url} not yet supported by `wb toolkit build` (use crate: or path:)"

  defp do_build_clause(id, %{build_src: {:unknown, spec}}),
    do: "#{id}: unrecognized #+BUILD_SRC #{inspect(spec)} (expected crate:<name> | git+<url> | path:<dir>)"

  defp error_text(reason) when is_binary(reason), do: String.slice(reason, -2000, 2000)
  defp error_text(reason), do: inspect(reason)

  @doc """
  `wb toolkit run <id> <task> -- <args...>` — extract the `:role task` bash block
  from the `<task>` skill and run it with positional `$1 $2 …` from <args>.
  """
  def run_task_text(id, task, args, root \\ default_root()) do
    # SECURITY (wb-sec, findings #4/#15/#16): the task slug is path-contained by
    # skill_path; the body is arbitrary bash, so execution is default-deny and
    # only runs sandboxed when opted-in (WB_TOOLKIT_EXEC=1).
    if not exec_allowed?() do
      "refusing to run #{id}/#{task}: toolkit bash execution is disabled (set WB_TOOLKIT_EXEC=1 to run sandboxed)"
    else
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
  end

  # Count :role pre blocks across a toolkit's skills (for the verify SKIPPED note).
  defp pre_block_count(dir) do
    Path.wildcard(Path.join([dir, "skills", "**", "*.org"]))
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
  defp exec_checks(%{exec: other}), do: [{false, "exec: unknown mode #{inspect(other)}"}]

  defp tk_dir(id, root) do
    case Enum.find(discover_dir(root), &(&1.id == id)) do
      %{dir: dir} -> dir
      _ -> nil
    end
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

  # thin skill: skills/<slug>.org ; thick skill: skills/<slug>/SKILL.org
  defp skill_path(dir, slug) do
    if safe_slug?(slug) do
      skills = Path.join(dir, "skills")
      thin = Path.join([dir, "skills", "#{slug}.org"])
      thick = Path.join([dir, "skills", slug, "SKILL.org"])

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

  defp manifest_kw(dir, key) do
    with {:ok, body} <- File.read(Path.join(dir, "manifest.org")),
         [_, v] <- Regex.run(~r/^#\+#{key}:\s*(.+)$/m, body) do
      String.trim(v)
    else
      _ -> nil
    end
  end

  defp captions(body),
    do: Regex.scan(~r/^[ \t]*#\+CAPTION:\s*(.+)$/m, body) |> Enum.map(fn [_, c] -> String.trim(c) end)

  @doc false
  # Extract the body of every `#+begin_src bash :role <role> …` block.
  def extract_role_blocks(content, role) do
    ~r/#\+begin_src\s+[^\n]*:role\s+#{role}\b[^\n]*\n(.*?)\n\s*#\+end_src/s
    |> Regex.scan(content)
    |> Enum.map(fn [_, body] -> body end)
  end

  # ── SECURITY TRUST BOUNDARY (wb-sec, findings #3/#13/#14/#15/#16/#17) ────────
  #
  # Executing a :role bash block from a discovered toolkit dir is REMOTE CODE
  # EXECUTION by design — the block body is arbitrary bash. The discovery root is
  # an unauthenticated, writable directory ($WB_TOOLKITS_ROOT or ./toolkits), so a
  # toolkit dropped there is UNTRUSTED supply-chain input, NOT "first-party".
  #
  # Defenses applied here:
  #   1. DEFAULT-DENY: bash execution is OFF unless the operator opts in via
  #      WB_TOOLKIT_EXEC=1 (an explicit, auditable trust grant). Read-only
  #      surfaces (list/show/search) never execute and stay open.
  #   2. SANDBOX: when execution IS granted, the snippet runs under
  #      Workbooks.Sandbox (network-DENIED, fs-confined) — not bare host bash.
  #   3. RESOURCE CAPS: a `ulimit` prologue (CPU seconds, max user processes,
  #      file size) blunts fork bombs / runaway loops, and a BEAM-side wall-clock
  #      watchdog kills the OS process tree on timeout so nothing wedges the host.
  #
  # The intended SANDBOXED surface for toolkit CLIs is the WASM `run-command`
  # path (Dock-gated). Host bash from skill files bypasses that entirely and is
  # therefore gated, capped, and isolated here.
  @exec_timeout_ms 30_000
  # ulimit prologue: -t CPU seconds, -u max user processes (anti fork-bomb),
  # -f max file size (512MB blocks * ... actually blocks), executed before the body.
  @ulimit_prologue "ulimit -t 30 -u 256 -f 1048576 2>/dev/null || true\n"

  @doc "Whether :role bash execution from discovered toolkits is opted-in (WB_TOOLKIT_EXEC=1)."
  def exec_allowed?, do: System.get_env("WB_TOOLKIT_EXEC") == "1"

  # Run a bash snippet with positional args ($1, $2, …) under the sandbox, capped.
  # Returns {output, exit_code}. The caller MUST have checked exec_allowed?.
  defp run_bash(body, args) do
    script = @ulimit_prologue <> body
    task = Task.async(fn -> Workbooks.Sandbox.run(["bash", "-c", script, "bash"] ++ args) end)

    case Task.yield(task, @exec_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {out, code}} -> {out, code}
      _ -> {"timed out after #{@exec_timeout_ms}ms", 124}
    end
  end

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
