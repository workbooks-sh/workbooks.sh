defmodule Workbooks.CLI.Demo do
  @moduledoc """
  `work demo …` — the demo-environment seed CLI (recording-system findings §3).

  Materializes a reproducible, fully-seeded Workbooks demo workspace from the
  git-backed Org fixture tree at `runtime/demos/seed/` via
  `Workbooks.Demos.Seed.materialize/1`.

      work demo seed              materialize (fresh) the whole demo env
      work demo seed --dry-run    print the plan; touch nothing, no app boot
      work demo seed --no-build   skip the slow tangle+build lanes (smoke seed)
      work demo seed --keep       don't wipe existing tenant repos first

  A real run boots the app (the build lane needs the wasmex NIF); `--dry-run`
  does not, so an agent can validate the plan cheaply.
  """

  alias Workbooks.Demos.Seed

  @doc "Entry for `work demo …`. Returns {output, failed?}."
  def run([]), do: {usage(), false}
  def run(["help"]), do: {usage(), false}

  def run(["seed" | flags]) do
    opts = [
      dry_run: "--dry-run" in flags,
      build: "--no-build" not in flags,
      fresh: "--keep" not in flags
    ]

    if opts[:dry_run] do
      report(Seed.materialize(opts))
    else
      # The build lane uses the wasmex NIF → needs the running app.
      case Application.ensure_all_started(:workbooks) do
        {:ok, _} -> report(Seed.materialize(opts))
        {:error, why} -> {"demo seed: app failed to start: #{inspect(why)}", true}
      end
    end
  rescue
    e -> {"demo seed FAILED: #{Exception.message(e)}", true}
  end

  def run(_), do: {usage(), true}

  # --- rendering -------------------------------------------------------------

  defp report(%{} = r) do
    tag = if r.dry_run, do: "DRY-RUN (no changes written)", else: "MATERIALIZED"

    members =
      Enum.map_join(r.members, "\n", fn m ->
        head = "  • #{pad(m.display, 16)} #{pad(m.role, 14)} ws=#{pad(m.workspace, 18)} #{m.did}"
        built = Map.get(m, :built, [])

        built_lines =
          for b <- built do
            case b.result do
              {:ok, comps} ->
                "      built #{b.workbook}: " <>
                  Enum.map_join(comps, ", ", fn c -> "#{c[:name]}/#{c[:lang]}→#{c[:output] || c[:error]}" end)

              other ->
                "      build #{b.workbook}: #{inspect(other)}"
            end
          end

        Enum.join([head | built_lines], "\n")
      end)

    toolkits =
      Enum.map_join(r.toolkits, "\n", fn t ->
        "  • #{pad(t.toolkit, 16)} #{Map.get(t, :signed, Map.get(t, :action))}"
      end)

    env = Enum.map_join(r.env, "\n", fn {k, v} -> "  export #{k}=#{v}" end)

    out = """
    Workbooks demo seed — #{tag}
    fixture tree: #{Path.relative_to_cwd(Seed.seed_dir())}
    data root:    #{r.data_root}
    toolkits root:#{r.toolkits_root}

    Team members (#{length(r.members)}):
    #{members}

    Custom toolkits (#{length(r.toolkits)}):
    #{toolkits}

    Dock preset: #{inspect(r.dock)}
    Replay transcripts: #{map_size(r.replay)} (served when WB_DEMO_REPLAY=1)

    Environment (the recording harness sources this before every take):
    #{env}
    """

    {String.trim_trailing(out), false}
  end

  defp pad(s, n), do: String.pad_trailing(to_string(s), n)

  defp usage do
    """
    work demo — the reproducible demo-environment seed

      work demo seed              materialize (fresh) the whole demo env from the
                                git-backed Org fixture tree (runtime/demos/seed)
      work demo seed --dry-run    print the plan; touch nothing, no app boot
      work demo seed --no-build   skip the tangle+build lanes (fast smoke seed)
      work demo seed --keep       keep existing tenant repos (no wipe)

    Seeds: 4 team members (ada/grace/alan/demo-bot) with STABLE DIDs, 3 real
    workspaces, built workbooks (real run records), 2 signed custom toolkits, a
    custom Dock preset, and replayed agent transcripts. Frozen clock + stable
    ids for byte-identical recordings.
    """
  end
end
