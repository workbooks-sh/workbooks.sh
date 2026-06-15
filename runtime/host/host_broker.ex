defmodule Workbooks.HostBroker do
  @moduledoc """
  SYNCHRONOUS host-import broker for the StarlingMonkey eval lane — the KEYSTONE residency fix (wb-b9xv).

  The SM eval-host's agent loop previously reached the host the only way SM could without a custom import:
  a guest `fetch()` to the pinned `wb-exec.internal` sentinel (`Workbooks.ExecLoopback`). That worked, but the
  wasi:http future backing each fetch is bound to ONE synchronous `function.call`; a fetch begun in turn N and
  awaited in turn N+1 (or concurrent in-flight async crossing the call boundary) poisons the http resource
  table / trips the component-model reentrancy guard — forcing the conservative "one turn per instance then
  recycle". (See `Workbooks.HarnessSessionTest` "the measured wall".)

  This module is the OTHER transport: the eval-host's WIT world now imports `wb:jseval/broker.host-call`, a
  SYNCHRONOUS component-model import (componentize-js@0.18.5: imported funcs are always sync). The guest calls
  `globalThis.__wbHostCall(jsonReq)`; the vendored wasmex linker does a blocking BEAM round-trip
  (`call_elixir_import` Condvar) to `dispatch/2` HERE, which performs the actual op (exec / fs / creds / llm
  egress with the host-held key) and returns the JSON response WITHIN THE SAME CALL — before the guest's
  `run()` returns. So NO wasi:http future ever straddles a run() boundary: re-entry is a non-issue BY
  CONSTRUCTION, and the agent loop stays RESIDENT on one instance across many turns with no recycle.

  SECURITY: identical spine to `ExecLoopback`. The grant is bound HOST-SIDE at construction (the guest sends
  NO token over this seam — the host closes over `grant`), so a guest can only ever reach exactly the
  exec/fs/creds the session was granted. Default-deny, principal-required for exec, posture-gated, workdir-
  confined fs (`Workbooks.WorkdirConfine`), no native exec (REGISTERED wasm commands only), output caps — all
  preserved. The LLM call is HOST-PERFORMED (`Workbooks.Llm` / the deterministic mock), so the guest never
  sees the API key.

  Request envelope (one JSON string in, one JSON string out):

      {"op":"exec","name":..,"argv":[..],"stdin":..}        -> {"ok":true,"out":<string>} | {"ok":false,..}
      {"op":"spawn","name":..,"argv":[..]}                  -> {"ok":true,"handle":..}    | {"ok":false,..}
      {"op":"stream","handle":..}                           -> {"ok":true,"chunk":..,"done":bool,"exit":n}
      {"op":"stdin","handle":..,"data":..}                  -> {"ok":true}                | {"ok":false,..}
      {"op":"fs","fsop":"read|write|append|stat|readdir|mkdir|exists|unlink","path":..,"data":..,"recursive":..}
                                                            -> {"ok":true,..}            | {"ok":false,"status":n,..}
      {"op":"llm","messages":[..],"tools":[..]}             -> {"ok":true,"resp":<msg>}   | {"ok":false,..}
      {"op":"creds.get","provider":..}                      -> {"ok":true,"found":bool,"blob":..}
      {"op":"creds.put","provider":..,"blob":..}            -> {"ok":true}
      {"op":"oauth.loopback", ...}                          -> {"ok":true,"code":..,"redirect_uri":..}
  """
  require Logger

  alias Workbooks.{ExecBroker, HarnessProc, HarnessCreds, OAuthLoopback, WorkdirConfine}

  @doc """
  Build the import-callback closure for `Wasmex.Components` (passed as `imports: %{"wb:jseval/broker" =>
  %{"host-call" => HostBroker.import_fn(grant)}}`). The closure is a 1-arg fn `(req_json) -> resp_json`. The
  GRANT (`%{allow, commands, principal, depth, creds_scope, workdir}`) is captured here — the guest sends no
  token over this seam. `grant == nil` => every op default-denies (no capability granted on this session).

  Streaming-child handles are keyed in a per-process table (`streams`) so a resident session's spawn/stream/
  stdin round-trips reach the same `HarnessProc`. The table is created lazily on first spawn.
  """
  def import_fn(grant) do
    fn req_json -> dispatch(req_json, grant) end
  end

  @doc false
  def dispatch(req_json, grant) when is_binary(req_json) do
    case Jason.decode(req_json) do
      {:ok, %{"op" => op} = req} -> do_op(op, req, grant)
      _ -> err("bad request json")
    end
  rescue
    e -> err("host-call crash: #{Exception.message(e)}")
  catch
    kind, reason -> err("host-call #{kind}: #{inspect(reason)}")
  end

  # ── exec (buffered one-shot) ───────────────────────────────────────────────────────────────────
  defp do_op("exec", req, grant) do
    with :ok <- gate(grant) do
      name = to_string(req["name"] || "")
      argv = Enum.map(req["argv"] || [], &to_string/1)
      stdin = to_string(req["stdin"] || "")

      if name == "" do
        err("exec: missing name")
      else
        case ExecBroker.exec(name, argv, stdin, broker_opts(grant)) do
          {:ok, out} -> ok(%{"out" => out})
          {:error, reason} -> err("exec denied: #{inspect(reason)}")
        end
      end
    end
  end

  # ── streaming child (spawn / stream / stdin) ───────────────────────────────────────────────────
  defp do_op("spawn", req, grant) do
    with :ok <- gate(grant) do
      name = to_string(req["name"] || "")
      argv = Enum.map(req["argv"] || [], &to_string/1)

      case ExecBroker.spawn_stream(name, argv, broker_opts(grant)) do
        {:ok, proc} ->
          handle = register_stream(proc)
          ok(%{"handle" => handle})

        {:error, reason} ->
          err("spawn denied: #{inspect(reason)}")
      end
    end
  end

  defp do_op("stream", req, grant) do
    with :ok <- gate(grant),
         {:ok, pid} <- lookup_stream(req["handle"]) do
      case safe_drain(pid) do
        {:ok, chunk, :open} ->
          ok(%{"chunk" => chunk, "done" => false})

        {:ok, chunk, {:exited, code}} ->
          drop_stream(req["handle"])
          ok(%{"chunk" => chunk, "done" => true, "exit" => code || 0})

        :dead ->
          drop_stream(req["handle"])
          ok(%{"chunk" => "", "done" => true, "exit" => 137})
      end
    else
      _ -> err("stream denied: no/invalid handle")
    end
  end

  defp do_op("stdin", req, grant) do
    with :ok <- gate(grant),
         {:ok, pid} <- lookup_stream(req["handle"]),
         :ok <- HarnessProc.write_stdin(pid, to_string(req["data"] || "")) do
      ok(%{})
    else
      _ -> err("stdin denied: no/invalid handle or closed child")
    end
  end

  # ── brokered fs (workdir-confined) ─────────────────────────────────────────────────────────────
  defp do_op("fs", req, grant) do
    fsop = req["fsop"]
    raw_path = req["path"]

    with :ok <- principal_ok(grant),
         false <- principal_revoked?(grant),
         {:ok, workdir} <- fs_workdir(grant),
         {:ok, abs} <- WorkdirConfine.confine(workdir, raw_path) do
      fs_dispatch(fsop, abs, req)
    else
      {:error, :no_workdir} -> err_status(403, "fs denied: no workdir granted on this run")
      {:error, :escape} -> err_status(403, "fs denied: path escapes the workdir")
      _ -> err_status(403, "fs denied: not granted")
    end
  end

  # ── host-performed LLM completion (the key never crosses the membrane) ─────────────────────────
  defp do_op("llm", req, grant) do
    with :ok <- principal_ok(grant) do
      messages = req["messages"] || []
      ok(%{"resp" => Workbooks.HostBrokerLLM.complete(messages, req["tools"] || [], grant)})
    else
      _ -> err("llm denied: not granted")
    end
  end

  # ── dock creds ─────────────────────────────────────────────────────────────────────────────────
  defp do_op("creds.get", req, grant) do
    with {:ok, user} <- creds_user(grant),
         {:ok, provider} <- creds_provider(grant, req["provider"]) do
      case HarnessCreds.get(user, provider) do
        {:ok, blob} -> ok(%{"found" => true, "blob" => blob})
        {:error, :not_found} -> ok(%{"found" => false})
      end
    else
      err -> err("creds denied: #{inspect(err)}")
    end
  end

  defp do_op("creds.put", req, grant) do
    with {:ok, user} <- creds_user(grant),
         {:ok, provider} <- creds_provider(grant, req["provider"]),
         blob when is_binary(blob) <- req["blob"],
         :ok <- HarnessCreds.put(user, provider, blob) do
      ok(%{})
    else
      err -> err("creds put denied: #{inspect(err)}")
    end
  end

  defp do_op("oauth.loopback", req, grant) do
    with :ok <- principal_ok_or_creds(grant) do
      params = %{
        "authorize_base" => req["authorize_base"],
        "code_challenge" => req["code_challenge"],
        "client_id" => req["client_id"],
        "scope" => req["scope"],
        "state" => req["state"]
      }

      case OAuthLoopback.start(params) do
        {:ok, %{code: code, redirect_uri: redirect_uri}} ->
          ok(%{"code" => code, "redirect_uri" => redirect_uri})

        {:error, :desktop_only} ->
          err_status(503, "oauth.loopback unavailable: desktop-only")

        {:error, reason} ->
          err_status(502, "oauth.loopback failed: #{inspect(reason)}")
      end
    else
      _ -> err("oauth denied: not granted")
    end
  end

  defp do_op(other, _req, _grant), do: err("unknown op: #{inspect(other)}")

  # ── grant gating (mirrors ExecLoopback's token/principal gates, but the grant is host-bound) ────

  # An exec-capable op requires a granted, principal-bearing grant (the broker's rate/concurrency/revoke
  # handle). nil grant or allow!=true => default-deny.
  defp gate(nil), do: err("denied: no grant on this session")

  defp gate(grant) do
    cond do
      Map.get(grant, :allow) != true -> err("denied: exec not granted")
      not valid_principal?(Map.get(grant, :principal)) -> err("denied: no principal")
      principal_revoked?(grant) -> err("denied: principal revoked")
      true -> :ok
    end
  end

  # fs/llm ops only need a principal-gated grant (allow may be false — an fs-only session is valid).
  defp principal_ok(nil), do: :error

  defp principal_ok(grant) do
    if Map.get(grant, :allow) != true or valid_principal?(Map.get(grant, :principal)),
      do: :ok,
      else: :error
  end

  defp principal_ok_or_creds(grant), do: if(grant, do: :ok, else: :error)

  defp broker_opts(grant) do
    [
      allow: Map.get(grant, :allow, false),
      commands: Map.get(grant, :commands, :all),
      principal: Map.get(grant, :principal),
      depth: Map.get(grant, :depth, 0) + 1
    ]
  end

  defp valid_principal?(p), do: is_binary(p) and p != ""

  defp principal_revoked?(grant) do
    case grant && Map.get(grant, :principal) do
      p when is_binary(p) and p != "" -> Workbooks.Revocation.revoked?(p)
      _ -> false
    end
  end

  # ── streaming-child registry (per BEAM process — the resident session GenServer owns its streams) ─

  @streams_key {__MODULE__, :streams}

  defp streams do
    case Process.get(@streams_key) do
      nil ->
        t = :ets.new(:hostbroker_streams, [:set, :private])
        Process.put(@streams_key, t)
        t

      t ->
        t
    end
  end

  defp register_stream(proc) do
    # The HarnessProc is start_link'd by ExecBroker FROM the current (GenServer-callback) process; that process
    # is long-lived (the resident session), so the link is fine to keep — the child dies with the session, or on
    # its own idle-eviction / explicit kill. Unlink anyway to match the loopback's lifetime model (the child's
    # lifetime is its own, not the spawner's transient call).
    Process.unlink(proc)
    handle = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    :ets.insert(streams(), {handle, proc})
    handle
  end

  defp lookup_stream(handle) when is_binary(handle) do
    case :ets.lookup(streams(), handle) do
      [{^handle, pid}] -> {:ok, pid}
      _ -> :error
    end
  end

  defp lookup_stream(_), do: :error

  defp drop_stream(handle) when is_binary(handle), do: :ets.delete(streams(), handle)
  defp drop_stream(_), do: :ok

  defp safe_drain(pid) do
    if Process.alive?(pid), do: HarnessProc.drain(pid), else: :dead
  rescue
    _ -> :dead
  catch
    :exit, _ -> :dead
  end

  # ── fs verbs (already-confined abs path) ───────────────────────────────────────────────────────

  defp fs_workdir(grant) do
    case grant && Map.get(grant, :workdir) do
      d when is_binary(d) and d != "" -> {:ok, Path.expand(d)}
      _ -> {:error, :no_workdir}
    end
  end

  defp fs_dispatch("read", abs, _req) do
    case File.read(abs) do
      {:ok, bin} -> ok(%{"data" => Base.encode64(bin)})
      {:error, :enoent} -> err_status(404, "ENOENT")
      {:error, :eisdir} -> err_status(403, "EISDIR")
      {:error, reason} -> err_status(500, to_string(reason))
    end
  end

  defp fs_dispatch("write", abs, req) do
    with {:ok, bytes} <- fs_decode(req["data"]),
         :ok <- File.mkdir_p(Path.dirname(abs)),
         :ok <- File.write(abs, bytes) do
      ok(%{})
    else
      _ -> err_status(500, "EIO")
    end
  end

  defp fs_dispatch("append", abs, req) do
    with {:ok, bytes} <- fs_decode(req["data"]),
         :ok <- File.mkdir_p(Path.dirname(abs)),
         :ok <- File.write(abs, bytes, [:append]) do
      ok(%{})
    else
      _ -> err_status(500, "EIO")
    end
  end

  defp fs_dispatch("exists", abs, _req), do: ok(%{"exists" => File.exists?(abs)})

  defp fs_dispatch("stat", abs, _req) do
    case File.stat(abs, time: :posix) do
      {:ok, %File.Stat{type: type, size: size, mtime: mtime}} ->
        ok(%{"size" => size, "is_dir" => type == :directory, "mtime_ms" => (mtime || 0) * 1000})

      {:error, :enoent} -> err_status(404, "ENOENT")
      {:error, reason} -> err_status(500, to_string(reason))
    end
  end

  defp fs_dispatch("readdir", abs, _req) do
    case File.ls(abs) do
      {:ok, entries} -> ok(%{"entries" => entries})
      {:error, :enoent} -> err_status(404, "ENOENT")
      {:error, reason} -> err_status(500, to_string(reason))
    end
  end

  defp fs_dispatch("mkdir", abs, req) do
    res = if req["recursive"], do: File.mkdir_p(abs), else: File.mkdir(abs)

    case res do
      :ok -> ok(%{})
      {:error, :eexist} -> ok(%{})
      {:error, reason} -> err_status(500, to_string(reason))
    end
  end

  defp fs_dispatch("unlink", abs, req) do
    res = if req["recursive"], do: File.rm_rf(abs), else: File.rm(abs)

    case res do
      :ok -> ok(%{})
      {:ok, _} -> ok(%{})
      {:error, :enoent} -> err_status(404, "ENOENT")
      {:error, reason, _} -> err_status(500, to_string(reason))
      {:error, reason} -> err_status(500, to_string(reason))
    end
  end

  defp fs_dispatch(_unknown, _abs, _req), do: err_status(400, "unknown fs op")

  defp fs_decode(nil), do: {:ok, ""}
  defp fs_decode(b64) when is_binary(b64), do: Base.decode64(b64)
  defp fs_decode(_), do: :error

  # ── creds scope (user fixed by the grant, never the request body) ──────────────────────────────

  defp creds_user(grant) do
    case grant && (get_in(grant, [:creds_scope, :user]) || (is_map(grant[:creds_scope]) && grant.creds_scope["user"])) do
      u when is_binary(u) and u != "" -> {:ok, u}
      _ -> {:error, :no_creds_scope}
    end
  end

  defp creds_provider(grant, requested) do
    scope = (grant && grant[:creds_scope]) || %{}
    granted = scope[:provider] || scope["provider"]
    allowed = scope[:providers] || scope["providers"]

    cond do
      is_binary(granted) and granted != "" -> {:ok, granted}
      is_list(allowed) and is_binary(requested) and requested in allowed -> {:ok, requested}
      true -> {:error, :provider_not_in_scope}
    end
  end

  # ── response helpers (always a JSON STRING — the import returns `string`) ───────────────────────

  defp ok(map), do: Jason.encode!(Map.put(map, "ok", true))
  defp err(msg), do: Jason.encode!(%{"ok" => false, "error" => msg})
  defp err_status(status, msg), do: Jason.encode!(%{"ok" => false, "status" => status, "error" => msg})
end
