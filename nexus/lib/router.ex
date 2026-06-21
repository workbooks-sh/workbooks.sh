defmodule Nexus.Router do
  @moduledoc """
  Explicit HTTP routes declared by a workbook's `server` units — the routing primitive of the
  native auth+routing feature (see `nexus/AUTH-ROUTING-RFC.md`, epic `wb-0uil`). Mirrors
  `Nexus.Live`: a global registry a unit fills at `register/0`, dispatched by `Nexus.Server`.

  A `server` unit declares routes with the `route/2` macro (imported into every unit):

      server :orders do
        route "GET  /api/orders",     :list
        route "POST /api/orders",     :create
        route "GET  /api/orders/:id", :show

        def list(req),   do: %{orders: Store.all(Order)}          # map → 200 JSON
        def create(req), do: {201, %{id: Store.create(Order, req.body)}}
        def show(req),   do: %{id: req.params["id"]}              # :id from the path
      end

  A handler takes a **request map** `%{params, query, body, method, path, tenant}` and returns:
  a map (→ 200 JSON), `{status, map}` (→ JSON), or `{status, content_type, binary}` (raw).
  Routes are global (like live-source names); collisions are the author's concern. Implicit
  `live/<source>` + `data/<resource>` are unaffected — this is for explicit HTTP handlers.

  NOTE: this primitive is auth-agnostic. Per-route GUARDS (`protect`) layer on in the auth phase
  (`wb-2vh1`) — the guard table is checked BEFORE dispatch, so adding routes here weakens nothing.
  """
  # persistent_term (like Nexus.Live) — survives the short-lived bringup-compile process that registers
  # routes; an ETS table would die with its creating process. Writes happen at bringup (rare); reads
  # are cheap. Keyed by {method, segment_pattern} → {module, fun}.
  @reg {__MODULE__, :routes}

  # Every `server` unit gets `use Nexus.Router` injected (see Nexus.Unit). `route` decls accumulate at
  # COMPILE time into a `__nexus_routes__/0` baked into the module — so they survive the content-
  # addressed compile cache (a module-body side effect would NOT). The nexus calls `install/1` at
  # bringup (which always runs, cached or fresh) to register them.
  defmacro __using__(_opts) do
    quote do
      import Nexus.Router, only: [route: 2]
      Module.register_attribute(__MODULE__, :nexus_routes, accumulate: true)
      @before_compile Nexus.Router
    end
  end

  @doc "Declare a route. `\"METHOD /path\"` (or just `\"/path\"`, default GET) → `fun/1` in this unit."
  defmacro route(spec, fun) when is_atom(fun) do
    quote do
      @nexus_routes {unquote(spec), unquote(fun)}
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      def __nexus_routes__, do: @nexus_routes
    end
  end

  @doc "Register a compiled unit's declared routes (called at bringup; no-op if it declares none)."
  def install(module) when is_atom(module) do
    if function_exported?(module, :__nexus_routes__, 0) do
      Enum.each(module.__nexus_routes__(), fn {spec, fun} -> add(spec, module, fun) end)
    end

    :ok
  end

  @doc "Register a route from a `\"METHOD /path\"` spec → `module.fun/1`. Called by the `route` macro."
  def add(spec, module, fun) when is_binary(spec) and is_atom(module) and is_atom(fun) do
    {method, path} = parse(spec)
    :persistent_term.put(@reg, Map.put(routes(), {method, segments(path)}, {module, fun}))
    :ok
  end

  @doc "All registered routes as `%{{method, segments} => {module, fun}}`."
  def routes, do: :persistent_term.get(@reg, %{})

  @doc ~S'Parse a `"GET /a/:b"` route spec into `{"GET", "/a/:b"}` (method upcased, default GET).'
  def parse(spec) do
    case String.split(String.trim(spec), ~r/\s+/, parts: 2) do
      [m, p] -> {String.upcase(m), normalize(p)}
      [p] -> {"GET", normalize(p)}
    end
  end

  @doc """
  Match a request `method` + `path` against the registered routes. Returns `{module, fun, params}`
  (params = the `:name` path captures) or `nil`. Most-specific (fewest captures) wins on ties.
  """
  def match(method, path) do
    method = String.upcase(to_string(method))
    want = segments(path)

    routes()
    |> Enum.filter(fn {{m, _pat}, _h} -> m == method end)
    |> Enum.map(fn {{_m, pat}, {mod, fun}} -> {pat, mod, fun, capture(pat, want)} end)
    |> Enum.reject(fn {_pat, _m, _f, caps} -> caps == nil end)
    |> Enum.sort_by(fn {_pat, _m, _f, caps} -> map_size(caps) end)
    |> case do
      [{_pat, mod, fun, caps} | _] -> {mod, fun, caps}
      [] -> nil
    end
  end

  @doc "Apply a matched handler to a request map; normalize its return into `{status, headers, body}`."
  def dispatch(module, fun, req) do
    result = do_dispatch(module, fun, req)
    instrument(module, fun, req)
    result
  end

  # #event auto-instrument: if the server unit carries #event, emit a route event (its other #tags ride along).
  defp instrument(module, fun, req) do
    if function_exported?(module, :__nexus_tags__, 0) do
      tags = module.__nexus_tags__()

      if "event" in tags do
        Nexus.Events.instrument(
          %{kind: "route", name: fun, refs: Enum.map(tags, &("#" <> &1))},
          %{kind: "route.#{fun}", title: req[:path] || req["path"], actor: to_string(fun), tenant: req[:tenant]}
        )
      end
    end
  rescue
    _ -> :ok
  end

  defp do_dispatch(module, fun, req) do
    case apply(module, fun, [req]) do
      {status, ct, body} when is_integer(status) and is_binary(ct) and is_binary(body) ->
        {status, ct, body}

      {status, %{} = map} when is_integer(status) ->
        {status, "application/json", Jason.encode!(map)}

      %{} = map ->
        {200, "application/json", Jason.encode!(map)}

      other ->
        {200, "application/json", Jason.encode!(%{result: other})}
    end
  rescue
    e -> {500, "application/json", Jason.encode!(%{error: Exception.message(e)})}
  end

  @doc "Drop all registered routes (test seam)."
  def reset, do: :persistent_term.put(@reg, %{})

  # ── internals ──
  defp normalize("/" <> _ = p), do: p
  defp normalize(p), do: "/" <> p

  defp segments(path) do
    path |> String.split("?", parts: 2) |> hd() |> String.split("/", trim: true)
  end

  # Match a pattern segment list against request segments; return %{param => value} or nil.
  defp capture(pat, want) when length(pat) == length(want) do
    Enum.zip(pat, want)
    |> Enum.reduce_while(%{}, fn
      {":" <> name, v}, acc -> {:cont, Map.put(acc, name, v)}
      {seg, seg}, acc -> {:cont, acc}
      {_a, _b}, _acc -> {:halt, nil}
    end)
  end

  defp capture(_pat, _want), do: nil
end
