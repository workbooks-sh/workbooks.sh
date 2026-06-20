defmodule Nexus.Toolkit.Caps do
  @moduledoc """
  The capability bridge for JS toolkits — **path-scoped** Dock caps + the `$host` JS binding.

  A toolkit runs as data in the shared StarlingMonkey eval-host (`Nexus.Toolkit.Js`). Its side-effects
  go ONLY through granted capabilities, never ambient. This module is the one place the partition path
  binds: every cap impl is bound to a `{operator, application, component}` path, so a toolkit can never
  address another app's / tenant's data — it names only a key; the host prefixes the path.

  This fixes the long-standing `Nexus.Dock` TODO (a hardcoded `"dock"` cache namespace + a global kv):
  here the namespace IS the path.

  Two halves:

    * `bind/2` → the HOST-side impls (`%{cap => fun}`) for the granted caps, bound to the path. These
      are what the eval-host's WIT imports resolve to (passed via `Wasmex.Components` once the eval-host
      declares the cap import interface — the build-machine step).
    * `host_js/1` → the GUEST-side `$host = {…}` JS binding the toolkit sees, referencing the
      engine-provided import globals (`__cap_*`). The contract the rebuilt eval-host satisfies.

  Deny-by-default: only caps named in `grants` are bound or exposed. An ungranted cap simply isn't there.
  """

  @caps ~w(emit store load cache_get cache_put cache_delete fetch complete)a

  @doc "The full set of grantable cap names (atoms)."
  def caps, do: @caps

  @doc """
  Host-side cap implementations for the granted caps, bound to `path` ({operator, application,
  component}). Returns `%{cap_atom => fun}`. Only granted caps are present (deny-by-default).
  """
  def bind(path, grants) when is_list(grants) do
    ns = path_key(path)
    granted = MapSet.new(Enum.map(grants, &normalize/1))

    %{
      emit: fn msg -> require(Logger) && Logger.info(["[toolkit ", ns, "] ", to_string(msg)]); nil end,
      store: fn k, v -> :persistent_term.put({:nexus_tk_kv, ns, to_string(k)}, to_string(v)); nil end,
      load: fn k -> :persistent_term.get({:nexus_tk_kv, ns, to_string(k)}, "") end,
      cache_get: fn k -> with({:ok, v} <- Nexus.Cache.get(ns, to_string(k)), do: v, else: (_ -> "")) end,
      cache_put: fn k, v, ttl -> Nexus.Cache.put(ns, to_string(k), to_string(v), ttl: ttl); nil end,
      cache_delete: fn k -> Nexus.Cache.delete(ns, to_string(k)); nil end,
      fetch: &Nexus.Dock.fetch/1,
      complete: &Nexus.Dock.llm_complete/1
    }
    |> Map.take(Enum.filter(@caps, &MapSet.member?(granted, &1)))
  end

  @doc """
  The guest-side `$host` JS binding for the granted caps — referencing engine-provided import globals
  (`__cap_<name>`). A `var $host = { … };` string the toolkit's transpiled JS calls. Ungranted caps
  are absent (calling one is a JS TypeError, i.e. deny-by-default at the guest too).
  """
  def host_js(grants) when is_list(grants) do
    members =
      grants
      |> Enum.map(&normalize/1)
      |> Enum.filter(&(&1 in @caps))
      |> Enum.uniq()
      |> Enum.map(fn cap -> "  #{cap}: __cap_#{cap}" end)
      |> Enum.join(",\n")

    "var $host = {\n#{members}\n};"
  end

  @doc """
  The WIT interface the eval-host must import to receive these caps (the contract for the build-machine
  rebuild). Generated from the granted caps so the world is minimal.
  """
  def wit(grants) when is_list(grants) do
    lines =
      grants
      |> Enum.map(&normalize/1)
      |> Enum.filter(&(&1 in @caps))
      |> Enum.uniq()
      |> Enum.map(&"  #{String.replace(to_string(&1), "_", "-")}: #{sig(&1)};")
      |> Enum.join("\n")

    "interface toolkit-caps {\n#{lines}\n}"
  end

  @doc """
  The `Wasmex.Components` import map for the granted caps, bound to `path` — `%{"<cap>" => {:fn, fun}}`.
  Passed as `opts[:imports]` to `Nexus.JsEngine.eval/2`; the rebuilt eval-host resolves its
  `toolkit-caps` WIT import to these. (Exact key format is verified against the cap-enabled engine —
  the import names follow the eval-host's declared interface.)
  """
  def imports(path, grants) do
    iface =
      path
      |> bind(grants)
      |> Map.new(fn {cap, fun} -> {String.replace(Atom.to_string(cap), "_", "-"), {:fn, fun}} end)

    %{Nexus.JsEngine.caps_iface() => iface}
  end

  @doc "A stable string key for a partition path. `{op, app, comp}` → \"op/app/comp\"."
  def path_key({operator, application, component}),
    do: Enum.map_join([operator, application, component], "/", &to_string/1)

  def path_key(other) when is_binary(other), do: other

  # ── helpers ─────────────────────────────────────────────────────────────────────────────────

  defp normalize(c) when is_atom(c), do: c
  defp normalize(c) when is_binary(c), do: Enum.find(@caps, :__unknown__, &(to_string(&1) == c))

  defp sig(:emit), do: "func(msg: string)"
  defp sig(:store), do: "func(key: string, val: string)"
  defp sig(:load), do: "func(key: string) -> string"
  defp sig(:cache_get), do: "func(key: string) -> string"
  defp sig(:cache_put), do: "func(key: string, val: string, ttl: u32)"
  defp sig(:cache_delete), do: "func(key: string)"
  defp sig(:fetch), do: "func(url: string) -> string"
  defp sig(:complete), do: "func(prompt: string) -> string"
end
