defmodule WorkCLI.Main do
  @moduledoc """
  `work` — the universal ecosystem CLI entrypoint. Parses global flags, configures the logging facade,
  routes to a verb group, and sets the process exit code. Local verbs run in `work_core`; engine/
  platform verbs (later phases) become a client to a nexus / control plane.
  """

  alias WorkCore.Log

  @version "0.1.0"

  def main(argv) do
    {flags, args} = extract_global_flags(argv)
    Log.configure(json: flags.json, color: flags.color)

    code =
      case route(args) do
        :ok -> 0
        {:error, _} -> 1
        n when is_integer(n) -> n
      end

    System.halt(code)
  end

  # ── global flags: --json (agent output), --no-color ─────────────────────────────────────────
  defp extract_global_flags(argv) do
    json = "--json" in argv
    no_color = "--no-color" in argv or System.get_env("NO_COLOR") not in [nil, ""]
    args = argv -- ["--json", "--no-color"]
    {%{json: json, color: not no_color and not json}, args}
  end

  # ── routing ─────────────────────────────────────────────────────────────────────────────────
  defp route([]), do: help()
  defp route(["help" | rest]), do: help(rest)
  defp route(["--help" | _]), do: help()
  defp route(["version" | _]), do: (Log.info("work #{@version}"); :ok)
  defp route(["--version" | _]), do: (Log.info("work #{@version}"); :ok)

  # author / literate — all local, over work_core
  defp route(["check" | rest]), do: WorkCLI.Work.check(dir_arg(rest))
  defp route(["lint" | rest]), do: WorkCLI.Work.lint(dir_arg(rest))
  defp route(["why", name | rest]), do: WorkCLI.Work.why(unit(name), dir_arg(rest))
  defp route(["near", name | rest]), do: WorkCLI.Work.near(unit(name), dir_arg(rest))
  defp route(["wit", name | rest]), do: WorkCLI.Work.wit(unit(name), dir_arg(rest))
  defp route(["structure" | rest]), do: WorkCLI.Work.structure(dir_arg(rest))
  defp route(["weave", dir, out | _]), do: WorkCLI.Work.weave(dir, out)
  defp route(["dev", dir | rest]), do: WorkCLI.Dev.watch(dir, List.first(rest) || default_out(dir))
  defp route(["dev"]), do: WorkCLI.Dev.watch(".", default_out("."))
  defp route(["weave" | _]), do: (Log.error("usage: work weave <dir> <out.html>"); {:error, :usage})

  # deploy — scaffold/validate local; apply/status/verify/logs/down route to a backend
  defp route(["deploy", "init" | rest]) do
    {place, dir} =
      case rest do
        [p, d | _] -> {p, d}
        [p] -> if p in ["local", "cloud"], do: {p, "."}, else: {"local", p}
        [] -> {"local", "."}
      end

    WorkCLI.Deploy.init(place, dir, force: "--force" in rest)
  end

  defp route(["deploy", "validate" | rest]), do: WorkCLI.Deploy.validate(file_arg(rest))
  defp route(["deploy", "apply" | rest]), do: WorkCLI.Deploy.apply(file_arg(rest))
  defp route(["deploy", "verify" | rest]), do: WorkCLI.Deploy.verify(List.first(rest) || "deployment.html")
  defp route(["deploy", "status" | rest]), do: WorkCLI.Deploy.status(file_arg(rest))
  defp route(["deploy", "down" | rest]), do: WorkCLI.Deploy.down(file_arg(rest))
  defp route(["deploy" | _]), do: (Log.error("usage: work deploy init|validate|apply|verify|status|down"); {:error, :usage})

  # platform — identity, contexts, the control plane
  defp route(["ctx"]), do: WorkCLI.Platform.ctx_list()
  defp route(["ctx", "list"]), do: WorkCLI.Platform.ctx_list()
  defp route(["ctx", "use", name | _]), do: WorkCLI.Platform.ctx_use(name)
  defp route(["ctx", "set", name | rest]), do: WorkCLI.Platform.ctx_set(name, flags(rest))
  defp route(["nexus", url | _]), do: WorkCLI.Platform.nexus(url)
  defp route(["whoami" | _]), do: WorkCLI.Platform.whoami()
  defp route(["login" | rest]), do: WorkCLI.Platform.login(positional(rest), flags(rest))

  defp route([verb | _]) do
    Log.error("unknown command: #{verb}", detail: "run `work help` for the full surface")
    {:error, :unknown}
  end

  # parse `--key value` flags → keyword list (atoms); positional = first non-flag, non-value token
  defp flags(args), do: flags(args, [])
  defp flags([], acc), do: Enum.reverse(acc)
  defp flags(["--" <> k, v | rest], acc), do: flags(rest, [{String.to_atom(k), v} | acc])
  defp flags([_ | rest], acc), do: flags(rest, acc)

  defp positional(["--" <> _, _v | rest]), do: positional(rest)
  defp positional([tok | _]) when binary_part(tok, 0, min(2, byte_size(tok))) != "--", do: tok
  defp positional(_), do: nil

  defp dir_arg(rest), do: List.first(rest) || "."
  defp file_arg(rest), do: (rest -- ["--force"]) |> List.first() || "deployment.html"
  defp default_out(dir), do: Path.basename(Path.expand(dir)) <> ".html"
  defp unit(name), do: String.trim_leading(to_string(name), ":")

  # ── the grouped verb map (the designed help) ────────────────────────────────────────────────
  @groups [
    {"author", "read & verify .work trees (local)", [
       {"check [dir]", "resolve every reference across the tree"},
       {"why :unit [dir]", "who depends on this unit"},
       {"near :unit [dir]", "the unit's immediate edges, in and out"},
       {"wit :unit [dir]", "print the generated WIT world for a unit"},
       {"structure [dir]", "list the units in the tree"}
     ]},
    {"build", "weave & compile (work_core + a nexus)", [
       {"weave <dir> <out.html>", "weave a tree into one self-contained html workbook"},
       {"dev <dir> [out.html]", "watch & re-weave on change (+ nexus hot-swap) — push-to-live"},
       {"build <dir>", "compile the units to wasm  (via a nexus)"}
     ]},
    {"deploy", "stand up a runtime, local or cloud", [
       {"deploy init [local|cloud]", "scaffold a deployment.html"},
       {"deploy validate", "coherence-check the config"},
       {"deploy apply", "deploy it (local microVM/container, or cloud)"},
       {"deploy verify|status|down", "health-check · inspect · tear down"}
     ]},
    {"platform", "identity, contexts, the cloud control plane", [
       {"ctx [list|use|set]", "manage targets (which nexus/org/workspace)"},
       {"nexus <url>", "point the active context at an engine"},
       {"login [url] · whoami", "authenticate to the control plane · show identity"}
     ]}
  ]

  defp help(_ \\ []) do
    Log.prompt("work")
    Log.info("  " <> Log.dim("the universal workbooks CLI — author, build, run, deploy"))
    Log.info("")

    for {name, blurb, verbs} <- @groups do
      Log.info(Log.cmd(name) <> "  " <> Log.dim(blurb))
      for {sig, desc} <- verbs do
        Log.info("  " <> Log.path(String.pad_trailing(sig, 26)) <> "  " <> desc)
      end
      Log.info("")
    end

    Log.info(Log.dim("global: --json (agent output) · --no-color"))
    :ok
  end
end
