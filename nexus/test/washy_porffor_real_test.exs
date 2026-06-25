defmodule Nexus.WashyPorfforRealTest do
  @moduledoc """
  **M3 conformance tracker — real-ish JS programs through the full Porffor lane.**

  The 57-probe census tests features in isolation; real code combines them (a template engine = regex +
  function-replacer + closures; a word counter = Map + spread + sort + regex split). This corpus
  (`test/conformance/porffor_real/*.js`) runs **realistic self-contained programs** through the whole lane
  (router → Porffor + AST pre-passes → Washy Sandbox) and diffs against the node oracle. It's a regression
  floor that rises as M3 fixes land — it does NOT require every program to pass yet (the failing ones are
  the active fork work-list). Skipped if porffor/node absent.
  """
  use ExUnit.Case, async: false

  @moduletag :porffor
  @dir Path.join(__DIR__, "conformance/porffor_real")

  # node oracles (`node <file>`), trimmed.
  @goldens %{
    "clsx_lib" => "a b d e",
    "csv_parse" => "3 3 a|b|c;1|2|3;4|5|6",
    "event_emitter" => "45",
    "expr_eval" => "14 20 4",
    "reducer" => "3 x",
    "template_engine" => "Hi Sam, you have 3 msgs",
    "word_count" => "the:3 cat:3 dog:1"
  }

  # Current passing floor — RAISE as M3 fixes land. (Baseline: csv_parse, reducer.)
  @floor 5

  setup_all do
    if File.regular?(Nexus.Compilers.Js.Porffor.porf_entry()) and System.find_executable("node"),
      do: :ok,
      else: {:skip, "porffor/node absent"}
  end

  defp run_one(name) do
    src = File.read!(Path.join(@dir, "#{name}.js"))

    with {:ok, wasm} <- Nexus.Compilers.Js.Porffor.compile(src),
         {:ok, out} <- Nexus.Washy.Sandbox.run_command(wasm, "", transpile: true, timeout_ms: 60_000) do
      {:ok, out |> String.replace(~r/\e\[[0-9;]*m/, "") |> String.trim()}
    end
  end

  test "real-program coverage does not regress below the floor" do
    results =
      for {name, want} <- @goldens do
        got = case run_one(name) do {:ok, o} -> o; _ -> :error end
        {name, got == want}
      end

    pass = Enum.count(results, fn {_, ok} -> ok end)
    failing = for {n, ok} <- results, not ok, do: n

    assert pass >= @floor,
           "porffor real-code regressed: #{pass}/#{map_size(@goldens)} (failing: #{Enum.join(failing, ", ")})"
  end
end
