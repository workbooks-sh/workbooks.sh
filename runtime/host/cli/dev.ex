defmodule Workbooks.CLI.Dev do
  @moduledoc """
  `wb dev …` — the development service for ANYONE running a Workbooks runtime:
  us (from a source checkout) and DeployKit users extending their own runtime.

  Host-side (no app boot — same as `wb rt`/`wb deploy`): it inspects the dev/demo
  environment and drives the local verification loop, so you never have to await
  a CI/CD → production build to see if something works. Two modes:

    * source checkout — the dev runtime boots from source (`mix`); the escript
      can't host the OQL/wasmex NIF, so `up`/`test` shell out to mix.
    * deployed runtime — your runtime is the container; `dev` is a client/harness
      against it over HTTP (reuses `wb rt` target resolution).
  """
  alias Workbooks.CLI.Runtime

  @doc "Entry for `wb dev …`. Returns {output, failed?}."
  def run([]), do: {usage(), false}
  def run(["help"]), do: {usage(), false}
  def run(["info"]), do: {info(), false}
  def run(["up" | _]), do: {up_text(), false}
  def run(["test" | rest]), do: mix(["test" | rest])
  def run(_), do: {usage(), true}

  # ── wb dev info — the demo/dev environment at a glance ──
  defp info do
    {target_line, health} =
      case Runtime.target() do
        {:ok, t} ->
          h =
            case Runtime.run(["get", "/health"]) do
              {_, false} -> "ok"
              {_, true} -> "unreachable"
            end

          {"#{t.url}  (source: #{t.source})", h}

        {:error, _} ->
          {"(none configured — set WB_RUNTIME_URL/WB_TOKEN or run a local daemon)", "n/a"}
      end

    root = toolkits_root()
    n = root |> Path.join("*/manifest.org") |> Path.wildcard() |> length()

    """
    Workbooks dev environment
      runtime:    #{target_line}   [health: #{health}]
      model key:  #{model_keys()}
      toolkits:   #{root}  (#{n} toolkit#{if n == 1, do: "", else: "s"})
      ctk shell:  (cd #{root}/ctk && python3 -m http.server 5180)  →  http://localhost:5180/ctk.html

    start a dev runtime (source):  WB_WEB=1 iex -S mix      # control plane on :4000
    prod-parity (krunvm):          wb deploy local
    run the test suite:            wb dev test
    """
  end

  defp model_keys do
    keys = ~w(OPENROUTER_API_KEY ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY GOOGLE_API_KEY)
    set = Enum.filter(keys, &(System.get_env(&1) not in [nil, ""]))
    if set == [], do: "none set (agent runs need one)", else: Enum.join(set, ", ") <> " set"
  end

  # Same resolution as Workbooks.Toolkits.default_root/0, inlined so `dev` stays
  # host-side (no app/NIF load from the escript).
  defp toolkits_root do
    env = System.get_env("WB_TOOLKITS_ROOT")

    cond do
      is_binary(env) and env != "" and File.dir?(env) -> env
      File.dir?("toolkits") -> "toolkits"
      File.dir?("../toolkits") -> "../toolkits"
      true -> "toolkits"
    end
  end

  # ── wb dev test — run the runtime test suite from a source checkout ──
  defp mix(args) do
    dir =
      cond do
        File.exists?("mix.exs") -> "."
        File.exists?("runtime/mix.exs") -> "runtime"
        true -> nil
      end

    if dir do
      {out, code} = System.cmd("mix", args, cd: dir, stderr_to_stdout: true)
      {out, code != 0}
    else
      {"no mix.exs found — `wb dev test` needs a source checkout. For a deployed runtime, drive it with `wb rt`.",
       true}
    end
  end

  defp up_text do
    """
    Start a dev runtime:
      source checkout →  WB_WEB=1 iex -S mix     # control plane on :4000
                         (add WB_DESKTOP=1 to also write the desktop discovery file)
      prod-parity     →  wb deploy local         # the same OCI image in a krunvm container

    Then:  wb dev info    ·    wb rt status
    """
  end

  defp usage do
    """
    wb dev — development service for a Workbooks runtime

      wb dev info          demo/dev environment at a glance (runtime, health, model key, toolkits, ctk)
      wb dev up            how to start a dev runtime (source mix / prod-parity krunvm)
      wb dev test [args]   run the runtime test suite (mix test) from a source checkout
      wb dev help          this help

    Planned: wb dev eval (agent eval suite), wb dev ctk <toolkit> (serve a render toolkit).
    """
  end
end
