defmodule Nexus.Toolkit.Js do
  @moduledoc """
  Transpile a **functional subset of Elixir** to JavaScript, so a toolkit authored in Elixir runs as
  data in the shared StarlingMonkey eval-host (`Nexus.JsEngine`) — no per-toolkit wasm build, no native
  toolchain. The author writes Elixir like everything else; this lowers it to JS over the real Elixir
  AST (`Code.string_to_quoted/1`, the same quoted form `Nexus.Literate` produces).

  Supported subset (what a toolkit actually needs — pure functions + capability calls):

    * multi-clause `def` with pattern dispatch
    * patterns: `[]`, `[h | t]`, tuples (`{:ok, v}`), atoms, ints/strings, vars, `_`
    * bodies: arithmetic (`+ - *`), string concat (`<>`), `to_string/1`, `String.upcase/1`,
      list/tuple literals, function calls (recursion), capability calls (`emit/1`, …)
    * self-tail-recursion → `while`-loop (TCO; Elixir has no loops, iteration *is* tail recursion)

  Not supported (a sandboxed toolkit shouldn't reach for these): processes/OTP, runtime macros,
  arbitrary NIFs, unrestricted IO. Side-effects go through granted capabilities, never ambient.

  Representation ABI (Gleam-JS style; see the vendored prelude): lists are cons cells
  (`Empty`/`NonEmpty` with `.head`/`.tail`), tuples are JS arrays, atoms are JS strings.

  `runnable/2` returns a self-contained classic script (prelude + the transpiled fns) suitable for
  `Nexus.JsEngine.eval/2`.
  """

  @prelude ~S"""
  // minimal toolkit prelude (cons-cell lists, Gleam-style ABI). Globals for classic eval.
  class $List {}
  class $Empty extends $List {}
  class $NonEmpty extends $List { constructor(head, tail) { super(); this.head = head; this.tail = tail; } }
  function $toList(arr) { let l = new $Empty(); for (let i = arr.length - 1; i >= 0; i--) l = new $NonEmpty(arr[i], l); return l; }
  function $prepend(x, l) { return new $NonEmpty(x, l); }
  """

  # ── public API ──────────────────────────────────────────────────────────────────────────────

  @doc "Transpile Elixir source (a set of `def`s) to JS function declarations. `{:ok, js} | {:error, _}`."
  def transpile(source) when is_binary(source) do
    case Code.string_to_quoted(source) do
      {:ok, ast} -> transpile_ast(ast)
      {:error, e} -> {:error, {:parse, e}}
    end
  end

  @doc "Transpile an already-quoted Elixir AST (e.g. `node.ast` from `Nexus.Literate`) to JS."
  def transpile_ast(ast) do
    case collect_defs(ast) do
      [] -> {:error, :no_defs}
      defs -> {:ok, defs |> group() |> Enum.map(&emit_fun/1) |> Enum.join("\n\n")}
    end
  rescue
    e -> {:error, {:transpile, Exception.message(e)}}
  end

  @doc """
  A self-contained classic script: the minimal prelude + the transpiled functions, with each `def`
  exposed as a global. Feed to `Nexus.JsEngine.eval/2` (which then calls a function by name, or you
  append a driver). `{:ok, js} | {:error, _}`.
  """
  def runnable(source, _opts \\ []) do
    with {:ok, js} <- transpile(source) do
      {:ok, prelude() <> "\n" <> js <> "\n"}
    end
  end

  @doc "The minimal cons-cell + helpers prelude (classic JS, globals)."
  def prelude, do: @prelude

  # ── collection / grouping ─────────────────────────────────────────────────────────────────────

  defp collect_defs({:__block__, _, items}), do: Enum.flat_map(items, &collect_defs/1)
  defp collect_defs({:def, _, [head, [do: body]]}), do: [clause(head, body)]
  defp collect_defs(_), do: []

  defp clause({name, _, params}, body) when is_atom(name) and is_list(params),
    do: {name, length(params), params, body}

  defp clause({name, _, ctx}, body) when is_atom(name) and is_atom(ctx),
    do: {name, 0, [], body}

  defp group(defs) do
    defs
    |> Enum.group_by(fn {n, a, _, _} -> {n, a} end)
    |> Enum.map(fn {{n, a}, cs} -> {n, a, Enum.map(cs, fn {_, _, p, b} -> {p, b} end)} end)
  end

  # ── function emission ─────────────────────────────────────────────────────────────────────────

  defp emit_fun({name, arity, clauses}) do
    args = if arity > 0, do: Enum.map(0..(arity - 1), &"a#{&1}"), else: []
    argl = Enum.join(args, ", ")
    tail? = Enum.any?(clauses, fn {_p, b} -> tail_self_call?(b, name, arity) end)

    inner =
      (clauses |> Enum.map(&emit_clause(&1, name, arity)) |> Enum.join("\n")) <>
        "\n  throw new Error(\"no clause matching #{name}/#{arity}\");"

    body =
      if tail? do
        "  while (true) {\n#{indent(inner, 1)}\n  }"
      else
        indent(inner, 0)
      end

    "function #{name}(#{argl}) {\n#{body}\n}"
  end

  defp emit_clause({params, body}, fname, arity) do
    {conds, binds} =
      params
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {pat, i}, {cs, bs} ->
        {c, b} = match(pat, "a#{i}")
        {cs ++ c, bs ++ b}
      end)

    cond_js = if conds == [], do: "true", else: Enum.join(conds, " && ")
    bind_js = binds |> Enum.map(fn {n, e} -> "let #{n} = #{e};" end) |> Enum.join(" ")
    "  if (#{cond_js}) { #{bind_js} #{emit_body(body, fname, arity)} }"
  end

  # ── pattern matching → {conditions, bindings} ─────────────────────────────────────────────────

  defp match({:_, _, _}, _e), do: {[], []}

  defp match({name, _, ctx}, e) when is_atom(name) and is_atom(ctx) and name != :_,
    do: {[], [{Atom.to_string(name), e}]}

  defp match([], e), do: {["#{e} instanceof $Empty"], []}

  defp match([{:|, _, [h, t]}], e) do
    {hc, hb} = match(h, "#{e}.head")
    {tc, tb} = match(t, "#{e}.tail")
    {["#{e} instanceof $NonEmpty"] ++ hc ++ tc, hb ++ tb}
  end

  defp match(a, e) when is_atom(a), do: {["#{e} === #{enc_atom(a)}"], []}
  defp match(s, e) when is_binary(s), do: {["#{e} === #{enc(s)}"], []}
  defp match(i, e) when is_integer(i) or is_float(i), do: {["#{e} === #{i}"], []}
  defp match({a, b}, e), do: tuple_match([a, b], e)
  defp match({:{}, _, elems}, e), do: tuple_match(elems, e)

  defp tuple_match(elems, e) do
    base = ["Array.isArray(#{e})", "#{e}.length === #{length(elems)}"]

    {cs, bs} =
      elems
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {el, i}, {cs, bs} ->
        {c, b} = match(el, "#{e}[#{i}]")
        {cs ++ c, bs ++ b}
      end)

    {base ++ cs, bs}
  end

  # ── body / expression emission ────────────────────────────────────────────────────────────────

  defp emit_body(body, fname, arity) do
    if tail_self_call?(body, fname, arity) do
      {_, _, callargs} = body

      assigns =
        callargs
        |> Enum.with_index()
        |> Enum.map(fn {a, i} -> "a#{i} = #{expr(a)}" end)
        |> Enum.join(", ")

      "{ #{assigns} }; continue;"
    else
      "return #{expr(body)};"
    end
  end

  defp tail_self_call?({n, _, a}, n, ar) when is_list(a) and length(a) == ar, do: true
  defp tail_self_call?(_, _, _), do: false

  defp expr(i) when is_integer(i) or is_float(i), do: to_string(i)
  defp expr(s) when is_binary(s), do: enc(s)
  defp expr(a) when is_atom(a), do: enc_atom(a)
  defp expr({:_, _, _}), do: "undefined"
  defp expr({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: Atom.to_string(name)

  defp expr({:__block__, _, stmts}) do
    {init, [last]} = Enum.split(stmts, -1)
    pre = init |> Enum.map(&"#{expr(&1)};") |> Enum.join(" ")
    "(() => { #{pre} return #{expr(last)}; })()"
  end

  defp expr({:+, _, [a, b]}), do: "(#{expr(a)} + #{expr(b)})"
  defp expr({:-, _, [a, b]}), do: "(#{expr(a)} - #{expr(b)})"
  defp expr({:*, _, [a, b]}), do: "(#{expr(a)} * #{expr(b)})"
  defp expr({:<>, _, [a, b]}), do: "(#{expr(a)} + #{expr(b)})"

  defp expr([]), do: "$toList([])"
  defp expr([{:|, _, [h, t]}]), do: "$prepend(#{expr(h)}, #{expr(t)})"
  defp expr(list) when is_list(list), do: "$toList([#{Enum.map_join(list, ", ", &expr/1)}])"

  defp expr({a, b}), do: "[#{expr(a)}, #{expr(b)}]"
  defp expr({:{}, _, elems}), do: "[#{Enum.map_join(elems, ", ", &expr/1)}]"

  defp expr({:to_string, _, [a]}), do: "String(#{expr(a)})"

  defp expr({{:., _, [{:__aliases__, _, [:String]}, :upcase]}, _, [a]}),
    do: "(#{expr(a)}).toUpperCase()"

  # capability call: a bare 1-arg call to a known cap → host bridge ($host.<cap>)
  defp expr({cap, _, [a]}) when cap in [:emit], do: "$host.#{cap}(#{expr(a)})"

  # generic call (recursion / sibling defs)
  defp expr({name, _, a}) when is_atom(name) and is_list(a),
    do: "#{name}(#{Enum.map_join(a, ", ", &expr/1)})"

  # ── helpers ───────────────────────────────────────────────────────────────────────────────────

  defp enc(s), do: ~s("#{s |> to_string() |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")}")
  defp enc_atom(a), do: enc(Atom.to_string(a))

  defp indent(s, n) do
    pad = String.duplicate("  ", n)
    s |> String.split("\n") |> Enum.map_join("\n", &if(&1 == "", do: "", else: pad <> &1))
  end
end
