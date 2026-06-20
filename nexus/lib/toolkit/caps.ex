defmodule Nexus.Toolkit.Caps do
  @moduledoc """
  The toolkit capability layer — **path-scoped ops on the shared host-broker seam**.

  Toolkits run as data in the StarlingMonkey eval-host (`Nexus.Toolkit.Js`), which imports the single
  synchronous `wb:jseval/broker.host-call: func(req: string) -> string` (bound to `globalThis.__wbHostCall`).
  Toolkit capabilities are **ops on that one seam** (`{"op":"store",…} -> {"ok":true,…}`), exactly like
  the node-compat ops (exec/fs/creds) the committed `nexus/compilers/js/shims-sm` already speak. There
  is NO separate per-toolkit import interface — one engine, one broker, one shared op vocabulary. This
  module is the live Nexus host-broker dispatcher (toolkit ops today; node-compat ops join here in
  `nexus/` as that lane is built).

  This module:

    * `dispatch/3` — the host-side op router for toolkit caps, **path-scoped** to a
      `{operator, application, component}` partition + **grant-filtered** (deny-by-default). The fn
      `JsEngine` wires to the `host-call` import for a toolkit invocation. Fixes the old hardcoded
      `"dock"` cache namespace / global kv: the namespace IS the path.
    * `host_js/1` — the guest-side `$host` binding: each granted cap is a JS wrapper over
      `__wbHostCall` with its op envelope. Ungranted caps are absent (and double-denied host-side).
  """

  @caps ~w(emit store load cache_get cache_put cache_delete fetch complete)a

  @doc "The grantable cap names (atoms)."
  def caps, do: @caps

  # ── host-side op dispatch (the broker fn for a toolkit invocation) ────────────────────────────

  @doc """
  A `host-call` closure for `Nexus.JsEngine` bound to `path` + `grants`: a 1-arg `(req_json) -> resp_json`
  fn that routes toolkit ops, path-scoped and grant-filtered. Pass as `opts[:broker]`.
  """
  def broker(path, grants), do: fn req_json -> dispatch(req_json, path, grants) end

  @doc "Route one host-call request (JSON in, JSON out), path-scoped + grant-filtered."
  def dispatch(req_json, path, grants) when is_binary(req_json) do
    granted = MapSet.new(Enum.map(grants, &normalize/1))
    ns = path_key(path)

    case Jason.decode(req_json) do
      {:ok, %{"op" => op} = req} -> do_op(op, req, ns, granted) |> Jason.encode!()
      _ -> Jason.encode!(%{"ok" => false, "error" => "bad request"})
    end
  rescue
    e -> Jason.encode!(%{"ok" => false, "error" => "host-call crash: #{Exception.message(e)}"})
  end

  defp do_op(op, req, ns, granted) do
    cap = op_cap(op)

    cond do
      cap == :__unknown__ -> %{"ok" => false, "error" => "unknown op: #{op}"}
      not MapSet.member?(granted, cap) -> %{"ok" => false, "error" => "capability not granted: #{cap}"}
      true -> run_op(op, req, ns)
    end
  end

  # op name → cap atom (dotted ops for the namespaced caps, matching the broker convention)
  defp op_cap("store"), do: :store
  defp op_cap("load"), do: :load
  defp op_cap("emit"), do: :emit
  defp op_cap("cache.get"), do: :cache_get
  defp op_cap("cache.put"), do: :cache_put
  defp op_cap("cache.delete"), do: :cache_delete
  defp op_cap("fetch"), do: :fetch
  defp op_cap("complete"), do: :complete
  defp op_cap(_), do: :__unknown__

  defp run_op("store", %{"key" => k, "val" => v}, ns) do
    :persistent_term.put({:nexus_tk_kv, ns, to_string(k)}, to_string(v))
    %{"ok" => true}
  end

  defp run_op("load", %{"key" => k}, ns),
    do: %{"ok" => true, "value" => :persistent_term.get({:nexus_tk_kv, ns, to_string(k)}, "")}

  defp run_op("emit", %{"msg" => m}, ns) do
    require Logger
    Logger.info(["[toolkit ", ns, "] ", to_string(m)])
    %{"ok" => true}
  end

  defp run_op("cache.get", %{"key" => k}, ns) do
    val = with({:ok, v} <- Nexus.Cache.get(ns, to_string(k)), do: v, else: (_ -> ""))
    %{"ok" => true, "value" => val}
  end

  defp run_op("cache.put", %{"key" => k, "val" => v} = req, ns) do
    Nexus.Cache.put(ns, to_string(k), to_string(v), ttl: Map.get(req, "ttl", 0))
    %{"ok" => true}
  end

  defp run_op("cache.delete", %{"key" => k}, ns) do
    Nexus.Cache.delete(ns, to_string(k))
    %{"ok" => true}
  end

  defp run_op("fetch", %{"url" => u}, _ns), do: %{"ok" => true, "body" => Nexus.Dock.fetch(to_string(u))}
  defp run_op("complete", %{"prompt" => p}, _ns), do: %{"ok" => true, "text" => Nexus.Dock.llm_complete(to_string(p))}
  defp run_op(_op, _req, _ns), do: %{"ok" => false, "error" => "bad op args"}

  # ── guest-side $host binding (wrappers over __wbHostCall) ──────────────────────────────────────

  @doc """
  The guest `$host` JS binding for the granted caps — each a wrapper over `__wbHostCall` with its op
  envelope. Ungranted caps are absent (calling one is a JS TypeError — deny-by-default at the guest).
  """
  def host_js(grants) do
    members =
      grants
      |> Enum.map(&normalize/1)
      |> Enum.filter(&(&1 in @caps))
      |> Enum.uniq()
      |> Enum.map(&"  #{wrapper(&1)}")
      |> Enum.join(",\n")

    "function $hc(o){return JSON.parse(__wbHostCall(JSON.stringify(o)));}\nvar $host = {\n#{members}\n};"
  end

  # per-cap JS wrapper: envelope in, value out
  defp wrapper(:store), do: ~S[store: (k, v) => { $hc({op:"store", key:k, val:String(v)}); return null; }]
  defp wrapper(:load), do: ~S[load: (k) => { var r = $hc({op:"load", key:k}); return r.ok ? r.value : ""; }]
  defp wrapper(:emit), do: ~S[emit: (m) => { $hc({op:"emit", msg:String(m)}); return null; }]
  defp wrapper(:cache_get), do: ~S[cache_get: (k) => { var r = $hc({op:"cache.get", key:k}); return r.ok ? r.value : ""; }]
  defp wrapper(:cache_put), do: ~S[cache_put: (k, v, ttl) => { $hc({op:"cache.put", key:k, val:String(v), ttl:(ttl||0)}); return null; }]
  defp wrapper(:cache_delete), do: ~S[cache_delete: (k) => { $hc({op:"cache.delete", key:k}); return null; }]
  defp wrapper(:fetch), do: ~S[fetch: (u) => { var r = $hc({op:"fetch", url:u}); return r.ok ? r.body : ""; }]
  defp wrapper(:complete), do: ~S[complete: (p) => { var r = $hc({op:"complete", prompt:p}); return r.ok ? r.text : ""; }]

  # ── helpers ───────────────────────────────────────────────────────────────────────────────────

  @doc "A stable string key for a partition path. `{op, app, comp}` → \"op/app/comp\"."
  def path_key({operator, application, component}),
    do: Enum.map_join([operator, application, component], "/", &to_string/1)

  def path_key(other) when is_binary(other), do: other

  defp normalize(c) when is_atom(c), do: c
  defp normalize(c) when is_binary(c), do: Enum.find(@caps, :__unknown__, &(to_string(&1) == c))
end
