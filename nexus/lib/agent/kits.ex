defmodule Nexus.Agent.Kits do
  @moduledoc """
  Kits — the agent's capabilities. A **kit is a wrapped CLI** (a `wasm32-wasi` command), run through
  `bash`. There are no discrete "tools"; everything the agent does, it does by running a kit's command
  in `bash`. `coreutils` is the **core kit** (ls/cat/grep/sed/echo/… — the whole unix base, one
  multicall wasm); additional kits are `*.wasm` dropped in the kits dir, each its own command.

  **Progressive disclosure** keeps the agent's context small:
    * level 1 — `summary/0`: a one-line catalog (kit names + what they do) goes in the system prompt.
    * level 2 — `help/1`: the agent runs `help <kit>` in bash to pull the command list / usage only
      when it needs that kit. It never carries every kit's full docs in context.

  `resolve/1` maps a command name (argv[0]) → `{wasm_path, leading_args}` so `bash` knows which wasm
  to run (e.g. `ls` → `{coreutils.wasm, ["ls"]}`; `jq` → `{jq.wasm, []}`).
  """

  # The coreutils applets (uutils 0.9.0) — the core kit's command surface.
  @coreutils ~w(arch base32 base64 basename cat cksum comm cp cut date dirname echo env expand
    expr factor false fmt fold head join link ln ls md5sum mkdir mktemp mv nl nproc od paste
    pr printenv printf ptx pwd readlink realpath rm rmdir seq sha1sum sha256sum shuf sleep sort
    split sum tac tail tee test touch tr true truncate tsort unexpand uniq unlink wc yes)

  @doc """
  The kits dir. `:kits_root` config wins; else the kits shipped alongside the compilers package
  (`<compilers_root>/kits` — where `stage-tools.sh` stages them, baked into the deployed image via
  `COPY --from=compilers`); else `<cwd>/kits` (dev, where the build drops `nexus/kits/*.wasm`).
  """
  def root do
    case Application.get_env(:nexus, :kits_root) do
      dir when is_binary(dir) and dir != "" ->
        dir

      _ ->
        compiled = Path.join(Nexus.Compilers.Shared.default_root(), "kits")
        if File.dir?(compiled), do: compiled, else: Path.join(File.cwd!(), "kits")
    end
  end

  @reg {:nexus_kits, :registered}

  @doc """
  Register a kit in-memory (no file). Used by `Nexus.Toolkit` to make a `toolkit` unit compiled from
  a `.work` file instantly available to the agent's `bash`. `opts`: `:summary`, `:commands`.
  """
  def register(name, wasm, opts \\ []) do
    kit = %{wasm: wasm, summary: Keyword.get(opts, :summary, "the #{name} toolkit"), commands: Keyword.get(opts, :commands, [name])}
    :persistent_term.put(@reg, Map.put(registered(), name, kit))
    :ok
  end

  @doc "Drop all in-memory registrations (e.g. between test runs)."
  def clear_registered, do: :persistent_term.put(@reg, %{})

  defp registered, do: :persistent_term.get(@reg, %{})

  @doc "All registered kits: `%{name => %{wasm, summary, commands}}`. coreutils + kits/*.wasm + in-memory."
  def all do
    extra =
      root()
      |> Path.join("*.wasm")
      |> Path.wildcard()
      |> Enum.reject(&(Path.basename(&1) == "coreutils.wasm"))
      |> Map.new(fn p ->
        name = Path.basename(p, ".wasm")
        {name, from_file(name, p)}
      end)

    core = %{
      "coreutils" => %{
        wasm: Path.join(root(), "coreutils.wasm"),
        summary: "core unix commands (ls, cat, grep-less base; see `help coreutils`)",
        commands: @coreutils
      },
      # host-brokered web access (not a wasm CLI — built into bash, SSRF-safe).
      "web" => %{
        wasm: nil,
        summary: "web: fetch/scrape (text), screenshot (png), navigate/links/click/fill/submit (operate a site)",
        commands: ["fetch", "scrape", "render", "screenshot", "navigate", "links", "forms", "click", "fill", "submit"]
      }
    }

    Map.merge(core, extra) |> Map.merge(registered())
  end

  @doc "Level-1 progressive disclosure: a one-line catalog for the agent's system prompt."
  def summary do
    all()
    |> Enum.map_join("\n", fn {name, k} -> "  #{name} — #{k.summary}" end)
  end

  @doc "Which kit a command belongs to — coreutils applet → \"coreutils\", web verb → \"web\", a kit's own command → that kit. Used to enforce an agent's `tools`."
  def kit_for(cmd) do
    cond do
      cmd in @coreutils -> "coreutils"
      cmd in ~w(fetch scrape render screenshot search navigate links forms click fill submit) -> "web"
      Map.has_key?(all(), cmd) -> cmd
      true -> Enum.find_value(all(), fn {n, k} -> if cmd in (k.commands || []), do: n end) || cmd
    end
  end

  @doc "Scoped catalog — only the named kits (an agent's declared `tools`). Least-privilege."
  def summary(names) when is_list(names) do
    want = MapSet.new(names)

    all()
    |> Enum.filter(fn {name, _} -> MapSet.member?(want, name) end)
    |> Enum.map_join("\n", fn {name, k} -> "  #{name} — #{k.summary}" end)
  end

  @doc "Level-2 progressive disclosure: a kit's command list / usage. `help <kit>` in bash calls this."
  def help(name) do
    case all()[name] do
      nil -> "no such kit: #{name}"
      %{commands: cmds} -> "#{name} provides:\n  " <> Enum.join(cmds, " ")
    end
  end

  @doc """
  Resolve a command name (argv[0]) to `{wasm_path, leading_args}`. The command name is passed to
  wasmtime as `--argv0`, so multicall binaries (coreutils) dispatch correctly without a leading
  applet arg. `nil` if no kit provides the command.
  """
  def resolve(cmd) do
    kits = all()

    cond do
      cmd in @coreutils ->
        # The multicall binary dispatches on argv[0]; bash sets `--argv0 <cmd>`, so no leading arg.
        {kits["coreutils"].wasm, []}

      Map.has_key?(kits, cmd) && kits[cmd].wasm ->
        {kits[cmd].wasm, []}

      true ->
        # a kit that lists `cmd` among its commands (e.g. a registered toolkit / manifested kit)
        case Enum.find(kits, fn {n, k} -> n != "coreutils" && k.wasm && cmd in (k.commands || []) end) do
          {_n, k} -> {k.wasm, []}
          nil -> nil
        end
    end
  end

  # Register an external kit. A sidecar manifest `<name>.kit` (plain text, NOT json) gives real
  # progressive disclosure — line 1 = the summary, line 2 = space-separated commands. Without one,
  # a sensible default (the kit provides one command = its own name).
  defp from_file(name, wasm) do
    manifest = Path.join(root(), "#{name}.kit")

    case File.read(manifest) do
      {:ok, body} ->
        [summary | rest] = String.split(String.trim(body), "\n", parts: 2)
        cmds = rest |> List.first("") |> String.split() |> default_if_empty([name])
        %{wasm: wasm, summary: String.trim(summary), commands: cmds}

      _ ->
        %{wasm: wasm, summary: "the #{name} command (drop a #{name}.kit manifest for details)", commands: [name]}
    end
  end

  defp default_if_empty([], default), do: default
  defp default_if_empty(list, _default), do: list
end
