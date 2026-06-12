defmodule Workbooks.JsDock do
  @moduledoc """
  Dock host-import surface for compiled-JS (QuickJS) commands built with the JsDock harness
  (harness_dock.o, wb-e1x.1) — the npm/JS analog of `Workbooks.RustDock`. Such a command imports
  `env.host_http_get` / `env.host_vfs_read` / `env.host_vfs_write` (exposed to JS as Javy.Net /
  Javy.VFS) and so MUST run under Wasmex with those imports backed by Policy-gated host fns —
  never under the bare `wasmtime run` CLI.

  Unlike RustDock (which gates by *presence* — a non-net Rust program simply omits the import),
  the JS harness ALWAYS imports all three (they're wired to the Javy.Net/Javy.VFS bindings), so we
  ALWAYS provide them and gate by BEHAVIOR: a denied cap's host fn returns -1, surfacing to JS as
  `Javy.Net.get(...) === null` / `Javy.VFS.*` failure. Untrusted JS still executes only inside
  QuickJS-under-wasmtime; the host owns the actual fs/net I/O (Route B). Zero native execution.
  """

  alias Workbooks.Policy

  @doc """
  Run a :dock-compiled JS command (Compilers.js_compile_to_wasm(.., dock: true)) under Wasmex with
  the profile's gated Dock imports. `input` is piped to stdin (Javy.IO); stdout is returned.
  opts: :profile (default :minimal), :timeout (ms), :vfs_db. Returns {:ok, stdout} | {:error, _}.
  """
  def run(wasm_path, input \\ "", opts \\ []) do
    profile = Keyword.get(opts, :profile, :minimal)
    timeout = Keyword.get(opts, :timeout, Policy.timeout(profile))
    vfs = if "vfs" in Policy.caps(profile), do: vfs_agent(opts), else: nil

    try do
      {:ok, si} = Wasmex.Pipe.new()
      {:ok, so} = Wasmex.Pipe.new()

      if input != "" do
        Wasmex.Pipe.write(si, input)
        Wasmex.Pipe.seek(si, 0)
      end

      bytes = File.read!(wasm_path)

      with {:ok, pid} <-
             Wasmex.start_link(%{
               bytes: bytes,
               store_limits: Policy.store_limits(profile),
               wasi: %Wasmex.Wasi.WasiOptions{stdin: si, stdout: so},
               imports: %{"env" => env(profile, vfs, Keyword.get(opts, :tenant, "default"))}
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

  # All three host fns are ALWAYS bound (the harness imports them unconditionally); each enforces
  # its own cap and returns -1 when denied → JS sees null/false. Egress is host-brokered (:httpc,
  # the wasm never opens a socket); VFS is the Instance's sandboxed KV store (no host FS reach).
  defp env(profile, vfs, tenant) do
    allow_http = Policy.allow_http?(profile)
    allow_exec = "exec" in Policy.caps(profile)
    allow_kv = "kv" in Policy.caps(profile)
    allow_secrets = "secrets" in Policy.caps(profile)
    allow_tcp = "tcp" in Policy.caps(profile)
    allow_udp = "udp" in Policy.caps(profile)

    %{
      "host_http_get" =>
        {:fn, [:i32, :i32, :i32, :i32], [:i32],
         fn ctx, url_ptr, url_len, out_ptr, out_cap ->
           if allow_http do
             url = Wasmex.Memory.read_string(ctx.caller, ctx.memory, url_ptr, url_len)

             # wb-broker SSRF floor on the host-mediated path (same as rust_dock).
             case Workbooks.NetGuard.get(url, principal: tenant) do
               {:ok, body} ->
                 n = min(byte_size(body), out_cap)
                 :ok = Wasmex.Memory.write_binary(ctx.caller, ctx.memory, out_ptr, binary_part(body, 0, n))
                 n

               {:error, _} ->
                 -1
             end
           else
             -1
           end
         end},
      # host_exec(req_ptr,req_len, out_ptr,out_cap) -> i32 : brokered exec to a sandboxed wasm command
      # (gated on the "commands" cap; ExecBroker enforces default-deny/registered-only/depth/cap/no-inject).
      "host_exec" =>
        {:fn, [:i32, :i32, :i32, :i32], [:i32],
         fn ctx, req_ptr, req_len, out_ptr, out_cap ->
           with true <- allow_exec,
                req = Wasmex.Memory.read_binary(ctx.caller, ctx.memory, req_ptr, req_len),
                {:ok, name, argv, stdin} <- Workbooks.ExecBroker.parse_request(req),
                {:ok, out} <- Workbooks.ExecBroker.exec(name, argv, stdin, allow: true, principal: tenant) do
             n = min(byte_size(out), out_cap)
             :ok = Wasmex.Memory.write_binary(ctx.caller, ctx.memory, out_ptr, binary_part(out, 0, n))
             n
           else
             _ -> -1
           end
         end},
      # Brokered data-parallelism (gated on commands cap). Mirrors rust_dock.
      "host_parallel_map" =>
        {:fn, [:i32, :i32, :i32, :i32], [:i32],
         fn ctx, rp, rl, op, oc ->
           with true <- allow_exec,
                req = Wasmex.Memory.read_binary(ctx.caller, ctx.memory, rp, rl),
                {:ok, name, argv, inputs} <- Workbooks.ParallelBroker.parse_map_request(req),
                {:ok, results} <- Workbooks.ParallelBroker.map(name, inputs, allow: true, argv: argv, principal: tenant) do
             enc = Workbooks.ParallelBroker.encode_results(results)

             if byte_size(enc) <= oc do
               :ok = Wasmex.Memory.write_binary(ctx.caller, ctx.memory, op, enc)
               byte_size(enc)
             else
               -1
             end
           else
             _ -> -1
           end
         end},
      # Durable per-tenant k/v (gated on vfs cap; tenant from the Dock, not the guest). Mirrors rust_dock.
      "host_kv_put" =>
        {:fn, [:i32, :i32, :i32, :i32], [:i32],
         fn ctx, kp, kl, vp, vl ->
           with true <- allow_kv,
                key = Wasmex.Memory.read_string(ctx.caller, ctx.memory, kp, kl),
                val = Wasmex.Memory.read_binary(ctx.caller, ctx.memory, vp, vl),
                :ok <- Workbooks.StorageBroker.Server.put(tenant, key, val) do
             0
           else
             _ -> -1
           end
         end},
      "host_kv_get" =>
        {:fn, [:i32, :i32, :i32, :i32], [:i32],
         fn ctx, kp, kl, op, oc ->
           with true <- allow_kv,
                key = Wasmex.Memory.read_string(ctx.caller, ctx.memory, kp, kl),
                {:ok, val} <- Workbooks.StorageBroker.Server.get(tenant, key) do
             n = min(byte_size(val), oc)
             :ok = Wasmex.Memory.write_binary(ctx.caller, ctx.memory, op, binary_part(val, 0, n))
             n
           else
             _ -> -1
           end
         end},
      # Secrets (gated on secrets cap; tenant from Dock). Sign with a host-held secret; never read it.
      "host_sign" =>
        {:fn, [:i32, :i32, :i32, :i32, :i32, :i32], [:i32],
         fn ctx, np, nl, dp, dl, op, oc ->
           with true <- allow_secrets,
                name = Wasmex.Memory.read_string(ctx.caller, ctx.memory, np, nl),
                data = Wasmex.Memory.read_binary(ctx.caller, ctx.memory, dp, dl),
                {:ok, sig} <- Workbooks.SecretBroker.sign(tenant, name, data) do
             n = min(byte_size(sig), oc)
             :ok = Wasmex.Memory.write_binary(ctx.caller, ctx.memory, op, binary_part(sig, 0, n))
             n
           else
             _ -> -1
           end
         end},
      # Brokered raw-TCP request/response (resolve-then-pin, SSRF-safe). Mirrors rust_dock.
      "host_tcp" =>
        {:fn, [:i32, :i32, :i32, :i32, :i32, :i32, :i32], [:i32],
         fn ctx, hp, hl, port, rp, rl, op, oc ->
           with true <- allow_tcp,
                host = Wasmex.Memory.read_string(ctx.caller, ctx.memory, hp, hl),
                req = Wasmex.Memory.read_binary(ctx.caller, ctx.memory, rp, rl),
                {:ok, resp} <- Workbooks.TcpBroker.request(host, port, req, principal: tenant) do
             n = min(byte_size(resp), oc)
             :ok = Wasmex.Memory.write_binary(ctx.caller, ctx.memory, op, binary_part(resp, 0, n))
             n
           else
             _ -> -1
           end
         end},
      # Brokered UDP send/recv-one (resolve-then-pin, SSRF-safe). Mirrors rust_dock.
      "host_udp" =>
        {:fn, [:i32, :i32, :i32, :i32, :i32, :i32, :i32], [:i32],
         fn ctx, hp, hl, port, dp, dl, op, oc ->
           with true <- allow_udp,
                host = Wasmex.Memory.read_string(ctx.caller, ctx.memory, hp, hl),
                dgram = Wasmex.Memory.read_binary(ctx.caller, ctx.memory, dp, dl),
                {:ok, resp} <- Workbooks.UdpBroker.request(host, port, dgram, principal: tenant) do
             n = min(byte_size(resp), oc)
             :ok = Wasmex.Memory.write_binary(ctx.caller, ctx.memory, op, binary_part(resp, 0, n))
             n
           else
             _ -> -1
           end
         end},
      "host_vfs_write" =>
        {:fn, [:i32, :i32, :i32, :i32], [:i32],
         fn ctx, pp, pl, dp, dl ->
           if vfs do
             path = Wasmex.Memory.read_string(ctx.caller, ctx.memory, pp, pl)
             data = Wasmex.Memory.read_binary(ctx.caller, ctx.memory, dp, dl)
             case Agent.get(vfs, fn conn -> Workbooks.VFS.put(conn, path, data) end) do
               :ok -> 0
               _ -> -1
             end
           else
             -1
           end
         end},
      "host_vfs_read" =>
        {:fn, [:i32, :i32, :i32, :i32], [:i32],
         fn ctx, pp, pl, op, oc ->
           if vfs do
             path = Wasmex.Memory.read_string(ctx.caller, ctx.memory, pp, pl)

             case Agent.get(vfs, fn conn -> Workbooks.VFS.get(conn, path) end) do
               {:ok, content} ->
                 n = min(byte_size(content), oc)
                 :ok = Wasmex.Memory.write_binary(ctx.caller, ctx.memory, op, binary_part(content, 0, n))
                 n

               _ ->
                 -1
             end
           else
             -1
           end
         end}
    }
  end
end
