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
      import Nexus.Router, only: [route: 2, route: 3]
      Module.register_attribute(__MODULE__, :nexus_routes, accumulate: true)
      @before_compile Nexus.Router
    end
  end

  @doc """
  Declare a route. `"METHOD /path"` (or just `"/path"`, default GET) → `fun/1` in this unit.

  The 3-arg form attaches a DECLARATIVE authorization policy (`wb-kodp`) the dispatcher enforces
  BEFORE the handler runs, so a route can never be reachable without its policy being checked first:

      route "GET  /cloud/data",       :data_list, auth: :member   # authenticated org member+
      route "POST /cloud/file/save",  :file_save, auth: :member
      route "GET  /cloud/tree",       :tree,      auth: :public    # explicitly world-readable
      route "POST /api/platform/...", :x,         auth: :admin

  Policy vocabulary (see `Nexus.Authz.route_allowed?/2`): `:public` (anyone, incl. anonymous — must be
  chosen explicitly), `:user` (any authenticated identity), `:member` / `:admin` / `:owner` (role floor).
  The 2-arg form attaches no policy (legacy); the route-policy test forbids shipping one for a cloud
  route, so every served route declares its own access rule — auditable from the route table alone.
  """
  defmacro route(spec, fun) when is_atom(fun) do
    quote do
      @nexus_routes {unquote(spec), unquote(fun), nil}
    end
  end

  defmacro route(spec, fun, opts) when is_atom(fun) do
    policy = Keyword.get(opts, :auth)

    quote do
      @nexus_routes {unquote(spec), unquote(fun), unquote(policy)}
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
      Enum.each(module.__nexus_routes__(), fn
        {spec, fun, policy} -> add(spec, module, fun, policy)
        {spec, fun} -> add(spec, module, fun, nil)
      end)
    end

    :ok
  end

  @doc "Register a route → `module.fun/1` with no policy (legacy/test seam)."
  def add(spec, module, fun), do: add(spec, module, fun, nil)

  @doc "Register a route from a `\"METHOD /path\"` spec → `module.fun/1`, with an auth `policy`."
  def add(spec, module, fun, policy) when is_binary(spec) and is_atom(module) and is_atom(fun) do
    {method, path} = parse(spec)
    :persistent_term.put(@reg, Map.put(routes(), {method, segments(path)}, {module, fun, policy}))
    :ok
  end

  @doc "All registered routes as `%{{method, segments} => {module, fun, policy}}`."
  def routes, do: :persistent_term.get(@reg, %{})

  @doc ~S'Parse a `"GET /a/:b"` route spec into `{"GET", "/a/:b"}` (method upcased, default GET).'
  def parse(spec) do
    case String.split(String.trim(spec), ~r/\s+/, parts: 2) do
      [m, p] -> {String.upcase(m), normalize(p)}
      [p] -> {"GET", normalize(p)}
    end
  end

  @doc """
  Match a request `method` + `path` against the registered routes. Returns `{module, fun, policy,
  params}` (params = the `:name` path captures) or `nil`. Most-specific (fewest captures) wins on ties.
  """
  def match(method, path) do
    method = String.upcase(to_string(method))
    want = segments(path)

    routes()
    |> Enum.filter(fn {{m, _pat}, _h} -> m == method end)
    |> Enum.map(fn {{_m, pat}, {mod, fun, policy}} -> {pat, mod, fun, policy, capture(pat, want)} end)
    |> Enum.reject(fn {_pat, _m, _f, _pol, caps} -> caps == nil end)
    |> Enum.sort_by(fn {_pat, _m, _f, _pol, caps} -> map_size(caps) end)
    |> case do
      [{_pat, mod, fun, policy, caps} | _] -> {mod, fun, policy, caps}
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
      # STREAMING: a handler returns {:stream, content_type, enumerable} to send
      # a chunked response — the server pipes each element through send_chunked,
      # so first bytes reach the client while the handler is still producing (the
      # first-audio-early lane for TTS). The enum may be a list, Stream, or any
      # Enumerable of iodata chunks.
      {:stream, ct, enum} when is_binary(ct) ->
        {:stream, ct, enum}

      # REDIRECT: {:redirect, url} → 302 with a Location header (OAuth callbacks).
      {:redirect, url} when is_binary(url) ->
        {:redirect, url}

      # WEBSOCKET: {:ws, handler_module, state} → upgrade the connection to a
      # WebSock handler (realtime lanes — the voice call).
      {:ws, mod, state} when is_atom(mod) ->
        {:ws, mod, state}

      # RAW CONN escape hatch: {:conn, fun} hands the handler the underlying Plug
      # conn (fun.(conn) → conn) for the rare Plug-centric flow that must set
      # cookies / redirect itself (OAuth session establishment). The `req`
      # abstraction covers everything else; this is the deliberate seam for the
      # few flows that genuinely need the connection.
      {:conn, fun} when is_function(fun, 1) ->
        {:conn, fun}

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
