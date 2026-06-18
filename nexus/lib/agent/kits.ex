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

  @doc "The kits dir (config `:kits_root`, default `nexus/kits`)."
  def root, do: Application.get_env(:nexus, :kits_root, Path.join(File.cwd!(), "kits"))

  @doc "All registered kits: `%{name => %{wasm, summary, commands}}`. coreutils + every kits/*.wasm."
  def all do
    extra =
      root()
      |> Path.join("*.wasm")
      |> Path.wildcard()
      |> Enum.reject(&(Path.basename(&1) == "coreutils.wasm"))
      |> Map.new(fn p ->
        name = Path.basename(p, ".wasm")
        {name, %{wasm: p, summary: "the #{name} command", commands: [name]}}
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
        summary: "web access: `fetch <url>` (raw body), `scrape <url>` (page as readable text)",
        commands: ["fetch", "scrape"]
      }
    }

    Map.merge(core, extra)
  end

  @doc "Level-1 progressive disclosure: a one-line catalog for the agent's system prompt."
  def summary do
    all()
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
  Resolve a command name (argv[0]) to `{wasm_path, leading_args}`. A coreutils applet → the
  coreutils wasm with the applet name as the first arg; a standalone kit → its wasm, no leading args.
  `nil` if no kit provides the command.
  """
  def resolve(cmd) do
    kits = all()

    cond do
      cmd in @coreutils -> {kits["coreutils"].wasm, [cmd]}
      Map.has_key?(kits, cmd) -> {kits[cmd].wasm, []}
      true -> nil
    end
  end
end
