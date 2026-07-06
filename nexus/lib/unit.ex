defmodule Nexus.Unit do
  @moduledoc """
  Run a **server** (native-BEAM) unit: its literate Elixir body *is* a module. This
  compiles a parsed `server` unit's AST into a real module on the BEAM and invokes its
  exports — the server tier of the linguistic model, Elixir all the way down, no wasm.

  (`client`/`sandbox` units compile to wasm components instead; this is the BEAM lane.)
  A whole workbook compiles its units in dependency order — `Nexus.Graph` gives that
  order so a unit's referenced units/types exist first; this is the single-unit step.
  """

  @doc """
  Compile a parsed `:code` unit into a BEAM module. Returns `{:ok, module}` or
  `{:error, reason}`. The unit's `do…end` body becomes the module body verbatim.
  """
  def compile(%{name: name, ast: ast} = node) when is_binary(name) and not is_nil(ast) do
    case do_body(ast) do
      nil ->
        {:error, :no_body}

      body ->
        mod = Module.concat([Nexus.Units, Nexus.Uid.camel(name) <> suffix()])

        # carry the unit's #tags into the module so the router can #event auto-instrument it.
        tags =
          node
          |> Map.get(:refs, [])
          |> Enum.filter(&String.starts_with?(&1, "#"))
          |> Enum.map(&String.trim_leading(&1, "#"))

        quoted =
          quote do
            defmodule unquote(mod) do
              use Nexus.Router
              def __nexus_tags__, do: unquote(tags)
              unquote(body)
            end
          end

        try do
          [{module, _bin}] = Code.compile_quoted(quoted)
          {:ok, module}
        rescue
          e -> {:error, Exception.message(e)}
        end
    end
  end

  def compile(_), do: {:error, :not_a_unit}

  @doc """
  Compile a whole workbook's BEAM tier: its type modules (`defmodule`) and `server`
  units, each to its **canonical** module name (so a unit's `Score.score/1` and
  `%Lead{}` references resolve). Types compile first so struct refs exist; cross-unit
  *calls* resolve at runtime, so no dependency sort is needed for compilation. Returns
  `{:ok, [module]}` or `{:error, {unit_name, reason}}`. (`client`/`sandbox`/`flow`/
  `agent` units are skipped — wasm lanes / DSL macros, not plain BEAM Elixir.)
  """
  def compile_workbook(root) do
    # Keep each node's source path so the trust gate (wb-rh95) can reject native-BEAM units authored in
    # an UNTRUSTED subtree — they must never compile to native Elixir on the host.
    node_paths =
      (Path.wildcard(Path.join(root, "*.work")) ++ Path.wildcard(Path.join(root, "**/*.work")))
      |> Enum.uniq()
      |> Enum.flat_map(fn p ->
        rel = Path.relative_to(p, root)
        Enum.map(Nexus.Literate.parse(File.read!(p)), &{&1, rel})
      end)

    {allowed, rejected} = Nexus.Trust.partition(node_paths)

    for {_node, path, {:untrusted_native_kind, kind, _}} <- rejected do
      require Logger
      Logger.warning("[trust] refused native `#{kind}` unit in untrusted workspace #{path} (wb-rh95)")
    end

    nodes = allowed
    code = Enum.filter(nodes, &(&1.type == :code and &1.ast != nil))

    # every `defmodule` ANYWHERE — top-level or nested inside any unit (e.g. Money in
    # a contract unit, Account in an agent) — is a type module the BEAM tier needs.
    type_mods =
      code
      |> Enum.flat_map(&collect_defmodules(&1.ast))
      # dedupe by the FULL module path, not the last segment — `Shadow.Hebb.Model` and
      # `Shadow.Surprise.Model` share a last segment ("Model"); the old last-segment
      # uniq silently DROPPED one, so it never compiled (invisible while a hand-written
      # `.ex` still defined it; a crash the moment `.work` is the sole source).
      |> Enum.uniq_by(&defmodule_path/1)
      |> Enum.reject(&(defmodule_name(&1) == nil))
      |> Enum.map(&%{type: :code, kind: "defmodule", name: defmodule_name(&1), ast: &1})

    servers = Enum.filter(code, &(&1.kind == "server" and &1.name != nil))

    # `compile_to_fixpoint` now accumulates `{module, beam_binary}` pairs. Surface the
    # bare module list under `:compiled` (unchanged for bringup/tests) and the pairs
    # under `:beams` (the ahead-of-time weave writes them to disk).
    r = compile_to_fixpoint(type_mods ++ servers, [])
    beams = List.flatten(r.compiled)
    %{compiled: Enum.map(beams, &elem(&1, 0)), beams: beams, failed: r.failed}
  end

  # every defmodule AST reachable in a tree (the node itself if it is one, plus nested)
  defp collect_defmodules(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _, _} = dm, acc -> {dm, [dm | acc]}
        other, acc -> {other, acc}
      end)

    Enum.reverse(acc)
  end

  defp defmodule_name({:defmodule, _, [{:__aliases__, _, mods} | _]}), do: mods |> List.last() |> to_string()
  defp defmodule_name(_), do: nil

  # the FULL alias path (`[:Shadow, :Surprise, :Model]`) — the identity for dedupe, so
  # same-named nested modules under different parents don't collide.
  defp defmodule_path({:defmodule, _, [{:__aliases__, _, mods} | _]}), do: mods
  defp defmodule_path(other), do: other

  # Fixpoint compile: each pass compiles what it can; nodes that fail on a not-yet-
  # compiled dependency (a `%Struct{}` whose module isn't loaded) retry next pass.
  # Stop when everything compiles or a pass makes no progress. No dependency sort
  # needed — the order falls out of what actually resolves.
  defp compile_to_fixpoint(pending, compiled) do
    {ok, failed} =
      Enum.reduce(pending, {[], []}, fn node, {ok, failed} ->
        case compile_named(node) do
          {:ok, mods} -> {List.wrap(mods) ++ ok, failed}
          {:error, reason} -> {ok, [{node, reason} | failed]}
        end
      end)

    cond do
      failed == [] ->
        %{compiled: compiled ++ ok, failed: []}

      ok == [] ->
        # no progress — the remaining failures are genuine, not ordering
        %{compiled: compiled, failed: Enum.map(failed, fn {n, r} -> {n[:name], r} end)}

      true ->
        compile_to_fixpoint(Enum.map(failed, fn {n, _} -> n end), compiled ++ ok)
    end
  end

  # a type module is already a `defmodule` — compile it as-is (it names itself).
  # Keep the FULL `{module, beam_binary}` pairs Code.compile_quoted returns — the
  # ahead-of-time weave (Mix.Tasks.Compile.Workbooks) writes those binaries to disk;
  # `compile_workbook/1` still surfaces the bare module list under `:compiled`.
  defp compile_named(%{kind: "defmodule", ast: ast}) do
    try do
      {:ok, Code.compile_quoted(ast)}
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  # a server unit's body becomes a module named for the unit (Score, Enrich, …)
  defp compile_named(%{kind: "server", name: name, ast: ast}) do
    case do_body(ast) do
      nil ->
        {:error, :no_body}

      body ->
        # Refuse a server name that would shadow a runtime-critical module (same hazard as
        # `resource Task` clobbering Elixir's stdlib `Task`). Fail at compile, not at boot.
        case Nexus.Uid.guard(name) do
          :ok -> :ok
          {:error, msg} -> raise msg
        end

        mod = Nexus.Uid.module(name)
        # Inject the routing primitive (`route "GET /path", :fun`) + the workbook-unit marker
        # (lets Nexus.Uid.guard/1 allow a recompile of this same unit).
        quoted =
          quote do
            defmodule unquote(mod) do
              use Nexus.Router
              def __nexus_unit__, do: true
              unquote(body)
            end
          end

        try do
          {:ok, Code.compile_quoted(quoted)}
        rescue
          e -> {:error, Exception.message(e)}
        end
    end
  end

  @doc """
  The `run_tests` weave gate: compile the workbook's BEAM tier, then run every `test`
  unit's cases on the BEAM. A `test :score` unit imports the unit under test (`Score`)
  so its `score(…)`/`%Lead{}` references resolve. Returns
  `%{passed: n, failed: [{unit, message}]}`.
  """
  def run_tests(root) do
    compile_workbook(root)

    (Path.wildcard(Path.join(root, "*.work")) ++ Path.wildcard(Path.join(root, "**/*.work")))
    |> Enum.uniq()
    |> Enum.flat_map(fn p -> Nexus.Literate.parse(File.read!(p)) end)
    |> Enum.filter(&(&1.type == :code and &1.kind == "test" and &1.name != nil))
    |> Enum.reduce(%{passed: 0, failed: []}, &run_test_unit/2)
  end

  defp run_test_unit(%{name: name, ast: ast}, acc) do
    case compile_test(name, ast) do
      {:error, reason} ->
        %{acc | failed: [{name, "won't compile: #{inspect(reason)}"} | acc.failed]}

      {:ok, module} ->
        Enum.reduce(Nexus.Unit.TestHarness.cases(module), acc, fn fun, a ->
          try do
            apply(module, fun, [])
            %{a | passed: a.passed + 1}
          rescue
            e -> %{a | failed: [{name, Exception.message(e)} | a.failed]}
          end
        end)
    end
  end

  defp compile_test(name, ast) do
    case do_body(ast) do
      nil ->
        {:error, :no_body}

      body ->
        under = Nexus.Uid.module(name)
        mod = Module.concat([Nexus.Uid.camel(name) <> "Tests" <> suffix()])

        quoted =
          quote do
            defmodule unquote(mod) do
              use Nexus.Unit.TestHarness
              import unquote(under)
              unquote(body)
            end
          end

        try do
          [{module, _bin}] = Code.compile_quoted(quoted)
          {:ok, module}
        rescue
          e -> {:error, Exception.message(e)}
        end
    end
  end

  @doc "Compile a server unit and invoke one of its exported functions."
  def run(node, fun, args) when is_atom(fun) and is_list(args) do
    case compile(node) do
      {:ok, module} -> apply(module, fun, args)
      {:error, _} = err -> err
    end
  end

  # the do-block body of a `kind :name[, opts] do … end` unit
  defp do_body({_kind, _meta, args}) when is_list(args) do
    case List.last(args) do
      [{:do, body}] -> body
      _ -> nil
    end
  end

  defp do_body(_), do: nil

  # keep module names unique so recompiles don't clash / warn
  defp suffix, do: "U#{System.unique_integer([:positive])}"
end
