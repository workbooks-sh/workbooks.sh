defmodule Mix.Tasks.Compile.Workbooks do
  use Mix.Task.Compiler

  @moduledoc """
  Weave a workbook's BEAM tier to real `.beam` **at build time** — the ahead-of-time
  lowering of `.work` to native artifacts, so the BEAM loads them like any Elixir
  module instead of the nexus runtime-compiling them at boot.

  This is the fix for the one place runtime `bringup` compilation is the wrong model:
  an app's OTP SUPERVISION TREE. A supervised GenServer authored in `.work` has to
  exist as a loaded module BEFORE it is supervised — but runtime-compile only brings it
  into being partway through `Application.start`, forcing pre-compile hacks and a
  double-compile every boot. Woven ahead of time, the tree boots from disk `.beam`; no
  chicken-and-egg, no hand-maintained `.ex` mirror. `.work` becomes the sole source;
  the `.beam` are generated artifacts under `_build`.

  It reuses the SAME compiler the runtime uses (`Nexus.Compile.workbook/1`) — no second
  code path, no new block kinds or verbs — then captures each module's binary with
  `:code.get_object_code/1` and writes it to `Mix.Project.compile_path/0`.

  Configure the surface(s) to weave in the host app's `mix.exs`:

      def project do
        [ compilers: [:workbooks | Mix.compilers()],
          workbook_surfaces: ["app/home"], ... ]
      end

  Runs BEFORE `:elixir` so the woven `.beam` are present when the app's own `.ex`
  (which call into them) compile — no undefined-module warnings. A generic cloud nexus
  that never runs this task still works: it runtime-`bringup`s the same `.work`. Same
  source, two lowering strategies.
  """

  @impl true
  def run(_argv) do
    surfaces = surfaces()

    if surfaces == [] do
      {:noop, []}
    else
      # The nexus compile pipeline is a dep (already built) but not started; the compile
      # path only needs persistent_term + the parser + trust, which work app-unstarted.
      Application.ensure_all_started(:nexus)
      dest = Mix.Project.compile_path()
      File.mkdir_p!(dest)

      {written, diagnostics} =
        Enum.reduce(surfaces, {0, []}, fn root, {n, diags} ->
          case weave(root, dest) do
            {:ok, count} -> {n + count, diags}
            {:error, ds} -> {n, ds ++ diags}
          end
        end)

      if written > 0, do: Mix.shell().info("Generated #{written} workbook module(s) → #{Path.relative_to_cwd(dest)}")

      status = if Enum.any?(diagnostics, &(&1.severity == :error)), do: :error, else: :ok
      {status, diagnostics}
    end
  end

  # Compile one surface's BEAM tier and emit each module's binary to disk. The binary
  # comes straight from `Code.compile_quoted` (via `:beams`) — NOT `:code.get_object_code`,
  # which only knows on-disk `.beam` and returns nothing for in-memory-compiled modules.
  defp weave(root, dest) do
    case Nexus.Unit.compile_workbook(root) do
      %{beams: beams, failed: failed} ->
        for {mod, bin} <- beams, do: File.write!(Path.join(dest, "#{mod}.beam"), bin)
        if failed == [], do: {:ok, length(beams)}, else: {:error, Enum.map(failed, &diag(root, &1))}

      _ ->
        {:ok, 0}
    end
  rescue
    e -> {:error, [diag(root, {nil, Exception.message(e)})]}
  end

  defp diag(root, {name, reason}) do
    %Mix.Task.Compiler.Diagnostic{
      compiler_name: "workbooks",
      file: root,
      message: "workbook unit #{inspect(name)} failed to weave: #{inspect(reason)}",
      position: nil,
      severity: :error
    }
  end

  # `workbook_surfaces` in the host project's config; each is a folder whose `**/*.work`
  # BEAM units are woven. Only existing dirs are kept (a misconfig is a no-op, not a crash).
  defp surfaces do
    Keyword.get(Mix.Project.config(), :workbook_surfaces, [])
    |> List.wrap()
    |> Enum.filter(&File.dir?/1)
  end
end
