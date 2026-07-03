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
  function $toArray(l) { let a = []; while (l instanceof $NonEmpty) { a.push(l.head instanceof $List ? $toArray(l.head) : l.head); l = l.tail; } return a; }
  function $out(r) { return r instanceof $List ? $toArray(r) : r; }
  """

  @reg {__MODULE__, :registry}

  # Reserved capability names — a call to one lowers to `$host.<name>(…)` (the cap bridge), not a
  # toolkit-function call. Mirrors Nexus.Toolkit.Caps.caps/0.
  @cap_names ~w(emit store load cache_get cache_put cache_delete fetch complete)a

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

  @doc "Exported functions of a toolkit source as `[{name, arity}]`. `{:ok, list} | {:error, _}`."
  def exports(source) when is_binary(source) do
    case Code.string_to_quoted(source) do
      {:ok, ast} -> {:ok, ast |> collect_defs() |> Enum.map(fn {n, a, _, _} -> {n, a} end) |> Enum.uniq()}
      {:error, e} -> {:error, {:parse, e}}
    end
  end

  # ── registry + build (the `toolkit` lane for Elixir-authored toolkits) ─────────────────────────

  @doc """
  Build an Elixir-authored `toolkit` node: transpile to runnable JS, register it, return `{:ok, name}`.
  Routed here from `Nexus.Toolkit.build/1` when the toolkit's language is Elixir.
  """
  def build(%{name: name, body: body}) do
    with {:ok, js} <- runnable(body),
         {:ok, exs} <- exports(body) do
      register(name, %{name: name, js: js, exports: exs})
      {:ok, name}
    end
  end

  @doc "Register a built JS toolkit under `name`."
  def register(name, entry) do
    :persistent_term.put(@reg, Map.put(registry(), to_string(name), entry))
    :ok
  end

  @doc "Look up a registered JS toolkit. `nil` if absent."
  def lookup(name), do: Map.get(registry(), to_string(name))

  @doc "Clear the JS-toolkit registry (test helper)."
  def clear, do: :persistent_term.put(@reg, %{})

  defp registry, do: :persistent_term.get(@reg, %{})

  # ── invocation (eval a toolkit function in the shared StarlingMonkey eval-host) ────────────────

  @doc """
  Invoke `fun` of a registered toolkit `name` (or pass a `{:js, src}` tuple for ad-hoc JS) with
  `args` (Elixir terms; lists become cons-lists, scalars pass through). Returns `{:ok, term} | {:error, _}`.

  `opts[:host]` — a JS snippet defining `$host` (the capability bridge). Defaults to a no-op stub;
  real path-scoped caps are wired by the eval-host (see the cap-bridge work).
  """
  def invoke(name_or_src, fun, args \\ [], opts \\ []) do
    with {:ok, js} <- resolve_js(name_or_src) do
      case opts[:engine] do
        :f2 -> invoke_f2(js, fun, args, opts)
        _ -> invoke_starling(js, fun, args, opts)
      end
    end
  end

  # StarlingMonkey (default): full ECMAScript + the cap-bridge broker; returns the last expression as a string.
  defp invoke_starling(js, fun, args, opts) do
    src = driver(js, fun, args, opts)
    # path-scoped, grant-filtered cap ops ride the shared host-call broker seam (deny-by-default)
    eval_opts =
      case {opts[:path], opts[:grants]} do
        {path, grants} when not is_nil(path) and is_list(grants) ->
          Keyword.put(opts, :broker, Nexus.Toolkit.Caps.broker(path, grants))

        _ ->
          opts
      end

    case Nexus.JsEngine.eval(src, eval_opts) do
      {:ok, out} -> decode(out)
      {:error, r} -> {:error, {:eval, r}}
    end
  end

  # F2 (JS→BEAM, `Nexus.F2` / TinyLasers.Gate.Exec): the confined, concurrent, warm-module/cold-process lane.
  # Runs the SAME toolkit script (print-based tail — F2 captures print() output), now with the FULL host-cap
  # bridge so it is a drop-in for StarlingMonkey (wb-adkrj). The grants are KEPT so `driver` builds the real
  # `$host` (which calls `__wbHostCall(json)`); the bridge below exposes `__wbHostCall` as a single granted Gate
  # capability wired to the SAME grant-filtered `Nexus.Toolkit.Caps.broker` StarlingMonkey uses. A Gate cap is
  # `%{fun: fn(args, ctx)}` (invoked by `Runtime.host_call/2`); `print` (id 0) is preserved, `__wbHostCall` is id 1.
  defp invoke_f2(js, fun, args, opts) do
    src = driver(js, fun, args, Keyword.put(opts, :engine, :f2))

    f2_opts =
      case {opts[:path], opts[:grants]} do
        {path, grants} when not is_nil(path) and is_list(grants) ->
          broker = Nexus.Toolkit.Caps.broker(path, grants)

          opts
          |> Keyword.put(:granted, %{"print" => 0, "__wbHostCall" => 1})
          |> Keyword.put(:caps, %{
            0 => %{fun: &TinyLasers.Gate.Runtime.cap_print/2},
            1 => %{fun: fn a, _ctx -> broker.(List.first(a) || "{}") end}
          })

        _ ->
          opts
      end

    case Nexus.F2.eval(src, f2_opts) do
      {:ok, lines} -> decode(List.last(lines) || "null")
      {:rejected, reason} -> {:error, {:f2_rejected, reason}}
      {:error, r} -> {:error, {:f2_eval, r}}
    end
  end

  @doc "The full classic script (prelude + toolkit + host + a `JSON.stringify($out(fun(args)))` tail). Exposed for testing."
  def driver(js, fun, args, opts \\ []) do
    host =
      cond do
        h = opts[:host] -> h
        grants = opts[:grants] -> Nexus.Toolkit.Caps.host_js(grants)
        true -> "var $host = { emit: function(_m){ return null; } };"
      end

    call = "#{fun}(#{Enum.map_join(args, ", ", &marshal/1)})"

    tail =
      if opts[:engine] == :f2 do
        # F2 captures print() output — print the JSON result on the last line.
        "print(JSON.stringify($out(" <> call <> ")));\n"
      else
        # StarlingMonkey returns the LAST expression coerced to string: assign then bare-reference $result.
        "var $result = JSON.stringify($out(" <> call <> "));\n$result\n"
      end

    js <> "\n" <> host <> "\n" <> tail
  end

  defp resolve_js({:js, src}) when is_binary(src), do: {:ok, src}
  defp resolve_js(name) do
    case lookup(name) do
      %{js: js} -> {:ok, js}
      nil -> {:error, {:unknown_toolkit, name}}
    end
  end

  # Elixir term → JS literal for an argument. Lists → cons-list; scalars via JSON.
  defp marshal(arg) when is_list(arg), do: "$toList(#{Jason.encode!(arg)})"
  defp marshal(arg) when is_integer(arg) or is_float(arg) or is_binary(arg) or is_boolean(arg),
    do: Jason.encode!(arg)
  defp marshal(arg) when is_atom(arg), do: Jason.encode!(Atom.to_string(arg))

  defp decode(""), do: {:ok, nil}
  defp decode(out) do
    case Jason.decode(out) do
      {:ok, v} -> {:ok, v}
      {:error, _} -> {:ok, out}
    end
  end

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

  # capability call: a bare call to a known cap name → host bridge ($host.<cap>(...)). The cap set is
  # the grantable Dock caps (Nexus.Toolkit.Caps.caps); these names are reserved (not toolkit fns).
  defp expr({cap, _, args}) when is_list(args) and cap in @cap_names,
    do: "$host.#{cap}(#{Enum.map_join(args, ", ", &expr/1)})"

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
