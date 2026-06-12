defmodule Workbooks.RustDock do
  @moduledoc """
  Dock host-import surface for compiled-Rust CORE modules (wb-49z/wb-1mv). Rust declares
  `extern "C"` fns; compiled via rust_compile_to_wasm(no_exceptions: true, allow_undefined: true)
  so they survive as `(import "env" <fn>)` and the wasm runs under Wasmex WITHOUT the exceptions
  proposal. `imports/1` returns the Wasmex core-module imports map backing those externs with
  POLICY-GATED host fns (the BEAM does the IO wasm can't: clock now, later vfs/http/llm). This is
  the offload lever — runtime caps wasm alone lacks, mediated by the host.
  """

  alias Workbooks.Policy

  @doc """
  env.* imports for a Rust core module. opts: :profile (caps gate, default :minimal).
  Ambient caps (host_now, host_log) always present; egress (host_http_get) ONLY when the profile
  permits HTTP (Policy.allow_http? — net/browse). Untrusted Rust on a non-net profile sees no
  http import → the extern is unresolved → wasm-ld --allow-undefined leaves it importable but
  Wasmex instantiation w/o the import fails the call, so DON'T request it from a minimal program.
  """
  def imports(opts \\ []) do
    profile = Keyword.get(opts, :profile, :minimal)
    caps = Policy.caps(profile)
    vfs = Keyword.get(opts, :vfs)
    tenant = Keyword.get(opts, :tenant, "default")

    env =
      ambient()
      |> maybe(Policy.allow_http?(profile), fn -> egress(tenant) end)
      |> maybe("vfs" in caps and vfs != nil, fn -> vfs_caps(vfs) end)
      |> maybe("exec" in caps, fn -> exec_caps(tenant) end)
      |> maybe("kv" in caps, fn -> kv_caps(tenant) end)
      |> maybe("secrets" in caps, fn -> secret_caps(tenant) end)
      |> maybe("queue" in caps, fn -> queue_caps(tenant) end)
      |> maybe("tcp" in caps, fn -> tcp_caps(tenant) end)

    %{"env" => env}
  end

  defp maybe(map, true, builder), do: Map.merge(map, builder.())
  defp maybe(map, _false, _builder), do: map

  # Exec dispatch — ONLY merged on the "commands" cap. The guest writes a length-prefixed request
  # (Workbooks.ExecBroker.parse_request) and the host runs the named REGISTERED wasm command in its own
  # sandboxed instance (no dirs passed → no host-file escalation; the catalog tools have no net). The
  # ExecBroker enforces default-deny / registered-only / depth / output-cap / structural-argv.
  defp exec_caps(principal) do
    %{
      # host_exec(req_ptr,req_len, out_ptr,out_cap) -> i32 : run a sandboxed wasm command, write its
      # output into the out buffer, return bytes written (truncated to out_cap; -1 on deny/error).
      "host_exec" =>
        {:fn, [:i32, :i32, :i32, :i32], [:i32],
         fn ctx, req_ptr, req_len, out_ptr, out_cap ->
           req = Wasmex.Memory.read_binary(ctx.caller, ctx.memory, req_ptr, req_len)

           with {:ok, name, argv, stdin} <- Workbooks.ExecBroker.parse_request(req),
                {:ok, out} <- Workbooks.ExecBroker.exec(name, argv, stdin, allow: true, principal: principal) do
             n = min(byte_size(out), out_cap)
             :ok = Wasmex.Memory.write_binary(ctx.caller, ctx.memory, out_ptr, binary_part(out, 0, n))
             n
           else
             _ -> -1
           end
         end},
      # host_parallel_map(req_ptr,req_len, out_ptr,out_cap) -> i32 : run a command over N inputs CONCURRENTLY
      # (brokered data-parallelism). Writes [n][(len,-1=err)(body)]* into out; -1 if out_cap too small.
      "host_parallel_map" =>
        {:fn, [:i32, :i32, :i32, :i32], [:i32],
         fn ctx, req_ptr, req_len, out_ptr, out_cap ->
           req = Wasmex.Memory.read_binary(ctx.caller, ctx.memory, req_ptr, req_len)

           with {:ok, name, argv, inputs} <- Workbooks.ParallelBroker.parse_map_request(req),
                {:ok, results} <- Workbooks.ParallelBroker.map(name, inputs, allow: true, argv: argv, principal: principal) do
             enc = Workbooks.ParallelBroker.encode_results(results)

             if byte_size(enc) <= out_cap do
               :ok = Wasmex.Memory.write_binary(ctx.caller, ctx.memory, out_ptr, enc)
               byte_size(enc)
             else
               -1
             end
           else
             _ -> -1
           end
         end}
    }
  end

  # Raw-TCP request/response — merged on the "tcp" cap. The host opens the (resolve-then-pinned, SSRF-safe)
  # connection; the guest never touches a socket. Tenant = revocation/rate principal.
  defp tcp_caps(tenant) do
    %{
      # host_tcp(host_ptr,host_len, port, req_ptr,req_len, out_ptr,out_cap) -> i32 : response len (-1 denied).
      "host_tcp" =>
        {:fn, [:i32, :i32, :i32, :i32, :i32, :i32, :i32], [:i32],
         fn ctx, hp, hl, port, rp, rl, op, oc ->
           host = Wasmex.Memory.read_string(ctx.caller, ctx.memory, hp, hl)
           req = Wasmex.Memory.read_binary(ctx.caller, ctx.memory, rp, rl)

           case Workbooks.TcpBroker.request(host, port, req, principal: tenant) do
             {:ok, resp} ->
               n = min(byte_size(resp), oc)
               :ok = Wasmex.Memory.write_binary(ctx.caller, ctx.memory, op, binary_part(resp, 0, n))
               n

             {:error, _} ->
               -1
           end
         end}
    }
  end

  # Inter-guest message queue — merged on the "queue" cap. Per-tenant topics; publish + poll (FIFO).
  defp queue_caps(tenant) do
    %{
      # host_publish(topic_ptr,topic_len, msg_ptr,msg_len) -> i32 : enqueue (0 ok, -1 full/denied).
      "host_publish" =>
        {:fn, [:i32, :i32, :i32, :i32], [:i32],
         fn ctx, tp, tl, mp, ml ->
           topic = Wasmex.Memory.read_string(ctx.caller, ctx.memory, tp, tl)
           msg = Wasmex.Memory.read_binary(ctx.caller, ctx.memory, mp, ml)

           case Workbooks.QueueBroker.publish(tenant, topic, msg) do
             :ok -> 0
             {:error, _} -> -1
           end
         end},
      # host_poll(topic_ptr,topic_len, out_ptr,out_cap) -> i32 : dequeue oldest (msg len, -1 empty/denied).
      "host_poll" =>
        {:fn, [:i32, :i32, :i32, :i32], [:i32],
         fn ctx, tp, tl, op, oc ->
           topic = Wasmex.Memory.read_string(ctx.caller, ctx.memory, tp, tl)

           case Workbooks.QueueBroker.poll(tenant, topic) do
             {:ok, msg} ->
               n = min(byte_size(msg), oc)
               :ok = Wasmex.Memory.write_binary(ctx.caller, ctx.memory, op, binary_part(msg, 0, n))
               n

             _ ->
               -1
           end
         end}
    }
  end

  # Secrets — merged on the "secrets" cap. The host holds the tenant's creds; the guest can SIGN with a
  # named secret but never read it. Tenant captured from the Dock.
  defp secret_caps(tenant) do
    %{
      # host_sign(name_ptr,name_len, data_ptr,data_len, out_ptr,out_cap) -> i32 : HMAC-SHA256 `data` with the
      # tenant's named secret; writes the signature into out, returns its length (-1 on unknown/denied).
      "host_sign" =>
        {:fn, [:i32, :i32, :i32, :i32, :i32, :i32], [:i32],
         fn ctx, np, nl, dp, dl, op, oc ->
           name = Wasmex.Memory.read_string(ctx.caller, ctx.memory, np, nl)
           data = Wasmex.Memory.read_binary(ctx.caller, ctx.memory, dp, dl)

           case Workbooks.SecretBroker.sign(tenant, name, data) do
             {:ok, sig} ->
               n = min(byte_size(sig), oc)
               :ok = Wasmex.Memory.write_binary(ctx.caller, ctx.memory, op, binary_part(sig, 0, n))
               n

             {:error, _} ->
               -1
           end
         end}
    }
  end

  # Durable k/v — merged on the "vfs" cap. The TENANT is captured from the Dock (the guest never names it),
  # so a guest can only ever touch its own persistent namespace. Backed by Workbooks.StorageBroker.Server.
  defp kv_caps(tenant) do
    %{
      # host_kv_put(key_ptr,key_len, val_ptr,val_len) -> i32 : 0 ok, -1 on deny/quota/error.
      "host_kv_put" =>
        {:fn, [:i32, :i32, :i32, :i32], [:i32],
         fn ctx, kp, kl, vp, vl ->
           key = Wasmex.Memory.read_string(ctx.caller, ctx.memory, kp, kl)
           val = Wasmex.Memory.read_binary(ctx.caller, ctx.memory, vp, vl)

           case Workbooks.StorageBroker.Server.put(tenant, key, val) do
             :ok -> 0
             {:error, _} -> -1
           end
         end},
      # host_kv_get(key_ptr,key_len, out_ptr,out_cap) -> i32 : value len written (-1 if missing/error).
      "host_kv_get" =>
        {:fn, [:i32, :i32, :i32, :i32], [:i32],
         fn ctx, kp, kl, op, oc ->
           key = Wasmex.Memory.read_string(ctx.caller, ctx.memory, kp, kl)

           case Workbooks.StorageBroker.Server.get(tenant, key) do
             {:ok, val} ->
               n = min(byte_size(val), oc)
               :ok = Wasmex.Memory.write_binary(ctx.caller, ctx.memory, op, binary_part(val, 0, n))
               n

             {:error, _} ->
               -1
           end
         end}
    }
  end

  @doc """
  Run a compiled-Rust CORE wasm (built via rust_compile_to_wasm no_exceptions: true) under Wasmex
  with the profile's gated Dock imports. Manages an in-memory VFS conn (Agent) for the vfs cap.
  Calls `_start`, returns {:ok, stdout} | {:error, reason}. opts: :profile (default :minimal),
  :timeout (ms). The single Dock-capable entry for the runtime rust-run path (wb-1mv).
  """
  def run(wasm_path, opts \\ []) do
    profile = Keyword.get(opts, :profile, :minimal)
    timeout = Keyword.get(opts, :timeout, Policy.timeout(profile))
    vfs = if "vfs" in Policy.caps(profile), do: vfs_agent(opts), else: nil

    try do
      {:ok, so} = Wasmex.Pipe.new()
      bytes = File.read!(wasm_path)

      with {:ok, pid} <-
             Wasmex.start_link(%{
               bytes: bytes,
               store_limits: Policy.store_limits(profile),
               wasi: %Wasmex.Wasi.WasiOptions{stdout: so},
               imports: imports(profile: profile, vfs: vfs, tenant: Keyword.get(opts, :tenant, "default"))
             }),
           {:ok, _} <- Wasmex.call_function(pid, "_start", [], timeout) do
        Wasmex.Pipe.seek(so, 0)
        {:ok, Wasmex.Pipe.read(so)}
      else
        {:error, _} = e -> e
        other -> {:error, other}
      end
    after
      if vfs, do: Agent.stop(vfs)
    end
  end

  defp vfs_agent(opts) do
    db = Keyword.get(opts, :vfs_db, ":memory:")
    {:ok, agent} = Agent.start_link(fn -> {:ok, conn} = Workbooks.VFS.open(db); conn end)
    agent
  end

  defp ambient do
    %{
        # host_now() -> i64 : unix epoch milliseconds (a real cap — wasm has no wall clock)
        "host_now" => {:fn, [], [:i64], fn _ctx -> System.os_time(:millisecond) end},
        # host_log(ptr,len) -> i32 : host READS the string from wasm linear memory + logs it.
        # Proves memory marshalling (caller.memory) — foundation for all string caps (http/vfs/llm).
        "host_log" =>
          {:fn, [:i32, :i32], [:i32],
           fn ctx, ptr, len ->
             s = Wasmex.Memory.read_string(ctx.caller, ctx.memory, ptr, len)
             IO.puts("[RustDock] host_log: #{s}")
             len
           end}
    }
  end

  # Egress — ONLY merged when Policy.allow_http? (net/browse profile). Untrusted Rust on a
  # minimal/non-net profile never gets this import → no host-mediated network.
  defp egress(principal) do
    %{
      # host_http_get(url_ptr,url_len, out_ptr,out_cap) -> i32 : host reads URL from wasm mem,
      # BEAM HTTP GET (the IO wasm cant do), writes body into out buffer, returns body len
      # (-1 err / truncates to out_cap). The offload lever — egress via BEAM, policy-gated.
      "host_http_get" =>
        {:fn, [:i32, :i32, :i32, :i32], [:i32],
         fn ctx, url_ptr, url_len, out_ptr, out_cap ->
           url = Wasmex.Memory.read_string(ctx.caller, ctx.memory, url_ptr, url_len)

           # wb-broker SSRF floor: deny internal/sensitive destinations BEFORE the socket opens.
           case Workbooks.NetGuard.get(url, principal: principal) do
             {:ok, body} ->
               n = min(byte_size(body), out_cap)
               :ok = Wasmex.Memory.write_binary(ctx.caller, ctx.memory, out_ptr, binary_part(body, 0, n))
               n

             {:error, _} ->
               -1
           end
         end},
      # wb-w5m: host_http_get_many(urls_ptr,urls_len, out_ptr,out_cap) -> i32 — the BATCH/CONCURRENT
      # primitive (the pragmatic async protocol). The wasm passes newline-joined URLs; the BEAM
      # fetches them CONCURRENTLY (Task.async_stream across processes — the parallelism wasm can't do)
      # and marshals the results back: [count:u32][ (len:i32, -1=failed) body ]*. Returns total bytes
      # written, or -1 if out_cap is too small. One Rust call → N concurrent requests → N results.
      "host_http_get_many" =>
        {:fn, [:i32, :i32, :i32, :i32], [:i32],
         fn ctx, urls_ptr, urls_len, out_ptr, out_cap ->
           _ = Application.ensure_all_started(:inets)
           _ = Application.ensure_all_started(:ssl)

           urls =
             Wasmex.Memory.read_string(ctx.caller, ctx.memory, urls_ptr, urls_len)
             |> String.split("\n", trim: true)

           results =
             urls
             |> Task.async_stream(
               fn url ->
                 # wb-broker SSRF floor applies per-URL in the concurrent batch too.
                 case Workbooks.NetGuard.get(url, principal: principal) do
                   {:ok, body} -> body
                   {:error, _} -> :error
                 end
               end,
               max_concurrency: 16,
               timeout: 15_000,
               on_timeout: :kill_task
             )
             |> Enum.map(fn
               {:ok, body} when is_binary(body) -> body
               _ -> :error
             end)

           blob =
             [<<length(results)::little-32>>
              | Enum.map(results, fn
                  :error -> <<-1::little-signed-32>>
                  body -> <<byte_size(body)::little-signed-32, body::binary>>
                end)]
             |> IO.iodata_to_binary()

           if byte_size(blob) > out_cap do
             -1
           else
             :ok = Wasmex.Memory.write_binary(ctx.caller, ctx.memory, out_ptr, blob)
             byte_size(blob)
           end
         end}
    }
  end

  # VFS — gated on "vfs" cap. `vfs` is an Agent pid holding the exqlite conn (the raw conn is NOT
  # valid on the Wasmex import-callback thread → {:error,:invalid_connection}; running the VFS op
  # INSIDE the Agent's BEAM process via Agent.get keeps the conn on a real scheduler). Sandboxed
  # key-value store (no host FS reach). Production: the owning Instance GenServer is that holder.
  defp vfs_caps(vfs) do
    %{
      # host_vfs_write(path_ptr,path_len, data_ptr,data_len) -> i32 (0 ok, -1 err)
      "host_vfs_write" =>
        {:fn, [:i32, :i32, :i32, :i32], [:i32],
         fn ctx, pp, pl, dp, dl ->
           path = Wasmex.Memory.read_string(ctx.caller, ctx.memory, pp, pl)
           data = Wasmex.Memory.read_binary(ctx.caller, ctx.memory, dp, dl)
           case Agent.get(vfs, fn conn -> Workbooks.VFS.put(conn, path, data) end) do
             :ok -> 0
             _ -> -1
           end
         end},
      # host_vfs_read(path_ptr,path_len, out_ptr,out_cap) -> i32 (bytes, -1 missing/err)
      "host_vfs_read" =>
        {:fn, [:i32, :i32, :i32, :i32], [:i32],
         fn ctx, pp, pl, op, oc ->
           path = Wasmex.Memory.read_string(ctx.caller, ctx.memory, pp, pl)
           case Agent.get(vfs, fn conn -> Workbooks.VFS.get(conn, path) end) do
             {:ok, content} ->
               n = min(byte_size(content), oc)
               :ok = Wasmex.Memory.write_binary(ctx.caller, ctx.memory, op, binary_part(content, 0, n))
               n

             _ ->
               -1
           end
         end}
    }
  end
end
