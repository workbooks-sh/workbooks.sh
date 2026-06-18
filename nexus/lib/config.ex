defmodule Nexus.Config do
  @moduledoc """
  Runtime configuration — sourced from the deployment's `<work-deploy>` element (HTML, the source
  of truth), **not** environment variables. Composition-as-source: a knob is an attribute you can
  read and diff in the file, never a hidden env sidecar (env config is JSON-by-another-name — same
  smell the NO-JSON rule forbids).

  The ONLY things still read from the process env are genuine deploy-time **secrets + per-machine
  identity** (`OPENROUTER_API_KEY`, `NEXUS_DATA_TOKEN`, `NEXUS_TENANT`) — loaded INTO the nexus at
  deploy from an env file, never authored config. Everything tunable lives here.

  Loaded once into `:persistent_term` (lazily on first read, or eagerly via `boot/0` at app start).
  `reload/1` (HTML string) and `put/2` are test seams.

      <work-deploy
        compile-concurrency="8"        # bound on concurrent wasm compiles (default: cores)
        compile-cache="on"             # content-addressed result cache (default: on)
        compile-cache-version="wbc1"   # bump to invalidate the whole store
        component-cache="build/components"   # store location (path or r2://bucket/prefix)
        languages="rust zig c"         # toolchains this deployment enables/pre-warms
        pm-debug="off" />
  """
  @key {__MODULE__, :cfg}

  # Conventional locations the deployed/dev nexus looks for its config, first hit wins. No env knob
  # points here — it's convention, so there's no bootstrap env var to "configure the config".
  @sources ["deployment.html", "/app/deployment.html", "/data/deployment.html"]

  @doc "Eagerly load + cache the config (call once at app start, before the Gate reads its limit)."
  def boot, do: load(locate())

  @doc "Parse `html` (or nil → all defaults) into the cached config map. Returns the map."
  def load(html) do
    cfg = parse(html)
    :persistent_term.put(@key, cfg)
    cfg
  end

  @doc "Re-read from an HTML string (tests)."
  def reload(html), do: load(html)

  @doc "Override one key in the cached config (tests)."
  def put(key, val) do
    cfg = Map.put(current(), key, val)
    :persistent_term.put(@key, cfg)
    val
  end

  defp current, do: :persistent_term.get(@key, nil) || boot()
  defp get(key), do: Map.fetch!(current(), key)

  # ── typed getters (the public surface the runtime calls — never System.get_env) ───────────────
  def compile_concurrency, do: get(:compile_concurrency)
  def compile_cache?, do: get(:compile_cache)
  def compile_cache_version, do: get(:compile_cache_version)
  def component_cache, do: get(:component_cache)
  def languages, do: get(:languages)
  def pm_debug?, do: get(:pm_debug)

  # ── parse ─────────────────────────────────────────────────────────────────────────────────────
  defp parse(html) do
    %{
      compile_concurrency: int(attr(html, "compile-concurrency"), System.schedulers_online()),
      compile_cache: bool(attr(html, "compile-cache"), true),
      compile_cache_version: attr(html, "compile-cache-version") || "wbc1",
      component_cache: attr(html, "component-cache") || default_cache_dir(),
      languages: words(attr(html, "languages"), :all),
      pm_debug: bool(attr(html, "pm-debug"), false)
    }
  end

  defp default_cache_dir, do: Path.join([File.cwd!(), "build", "components"])

  # Mirror the reactor's lightweight reader: find the attribute on the <work-deploy> open tag. No
  # full HTML parser needed for a flat attribute list.
  defp attr(nil, _name), do: nil

  defp attr(html, name) do
    case Regex.run(~r/<work-deploy\b[^>]*?\b#{Regex.escape(name)}="([^"]*)"/s, html) do
      [_, v] -> String.trim(v)
      _ -> nil
    end
  end

  defp int(nil, default), do: default

  defp int(s, default) do
    case Integer.parse(s) do
      {n, _} when n > 0 -> n
      _ -> default
    end
  end

  defp bool(nil, default), do: default
  defp bool(s, _default) when is_binary(s), do: String.downcase(s) in ~w(on true yes 1)
  defp bool(b, _default) when is_boolean(b), do: b

  defp words(nil, default), do: default
  defp words(s, _default) when is_binary(s), do: String.split(s, ~r/\s+/, trim: true)
  defp words(list, _default) when is_list(list), do: list

  defp locate, do: Enum.find_value(@sources, fn p -> if File.regular?(p), do: File.read!(p) end)
end
