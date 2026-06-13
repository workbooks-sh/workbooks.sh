defmodule Workbooks.PyNet do
  @moduledoc """
  wb-broker PYTHON BROKERED-TRANSPORT — gives a wasip1 runtime (CPython 3.12, QuickJS, …) SSRF-safe outbound
  HTTP even though it has NO outbound socket of its own.

  The wall (iter134): the provisioned CPython is a wasip1 CORE module whose only wasi socket imports are
  sock_accept/recv/send/shutdown — NO sock_connect. It physically cannot open an outbound connection, so wiring
  brokered networking to the wasi socket path can't help (the module never calls connect). Brokered net
  (socket_addr_check) only intercepts the wasip2/wasi:sockets path.

  The fix: the HOST does the network. The guest and host share a preopened directory and speak a tiny
  request/response FILE protocol (the only IPC a wasip1 runtime has: fd_read/fd_write). The guest writes a
  request file + a `.ready` marker; a concurrent host watcher services it through `NetGuard.request/3` — the
  SAME SSRF + resolve-then-pin + allow-list + rate/revocation cadence as every other egress — and writes a
  response file + marker. The guest never touches a socket; the host is the only thing that talks to the
  network, fully mediated. This is the "host does the privileged op, guest stays sandboxed" rule applied to a
  runtime that can't even attempt the op.

  Protocol (in the shared dir, default mount `/b`):
    * guest writes `req.json`  = {"method","url","headers"?,"body_b64"?,"allow"?}, then `req.ready`
    * host reads them, calls NetGuard.request, writes `resp.json` = {"ok":bool,"status"?,"body_b64"?,"error"?},
      then `resp.ready`; removes the request markers
    * guest polls for `resp.ready`, reads `resp.json`, removes `resp.ready`
  Many sequential requests reuse the same dir (one in flight at a time — a wasip1 guest is single-threaded).

  Security: every serviced request goes through NetGuard.request, so the full red-team-green floor applies
  (loopback/link-local/RFC1918/CGNAT/metadata denied, DNS-rebind pinned, allow-list default-deny when given,
  per-principal rate + revocation). A malicious guest can at most write garbage request files — it still can't
  reach an internal target, because the HOST re-validates every URL.
  """
  require Logger

  @poll_ms 20
  # safety ceiling so a wedged guest can't spin the watcher forever
  @default_deadline_ms 30_000
  @default_max_requests 64

  @doc """
  Run CPython `script` (a Python program string, passed as `-c`) with a brokered-HTTP transport mounted at
  `/b`. While the script runs, a concurrent host watcher services its HTTP request-files via `NetGuard.request`.
  Returns the script's stdout (`{:ok, out}`), `{:error, reason}` on failure.

  opts: `:allow` (host allow-list applied to EVERY brokered request, default deny-list/SSRF floor only),
  `:principal` (rate/revocation), `:rate`, `:deadline_ms`, `:max_requests`, `:mount` (guest mount, default
  `"/b"`), `:dirs` (extra read preopens, e.g. the python stdlib pack).
  """
  def run_python(script, opts \\ []) when is_binary(script) do
    mount = Keyword.get(opts, :mount, "/b")
    bdir = Path.join(System.tmp_dir!(), "pynet_#{System.unique_integer([:positive])}")
    File.mkdir_p!(bdir)

    parent = self()
    stop = make_ref()

    # the watcher runs concurrently with the (blocking) CPython run, servicing request-files as they appear.
    watcher =
      spawn_link(fn -> watch_loop(bdir, opts, parent, stop, Keyword.get(opts, :max_requests, @default_max_requests)) end)

    dirs = ["#{bdir}::#{mount}" | Keyword.get(opts, :dirs, [])]

    try do
      out = Workbooks.CommandRegistry.run("python", "", ["-c", script], dirs)

      case out do
        {:ok, body} -> {:ok, body}
        body when is_binary(body) -> {:ok, body}
        {body, _status} when is_binary(body) -> {:ok, body}
        other -> {:error, {:run_failed, other}}
      end
    after
      send(watcher, {stop, :done})
      File.rm_rf(bdir)
    end
  end

  @doc """
  Convenience: do a single brokered HTTP request FROM inside CPython and return the response — proves the
  transport end to end. Runs a tiny Python client that uses the file protocol, returns `{:ok, %{status, body}}`.
  """
  def fetch(method, url, opts \\ []) when is_binary(url) do
    m = method |> to_string() |> String.upcase()
    # minimal in-guest client: write request, poll for response, print "status\n<len>" so the host can parse it.
    script = """
    import json, os, time, base64
    req = {"method": #{inspect(m)}, "url": #{inspect(url)}}
    open("/b/req.json", "w").write(json.dumps(req))
    open("/b/req.ready", "w").write("1")
    out = {"ok": False, "error": "timeout"}
    for _ in range(1500):
        if os.path.exists("/b/resp.ready"):
            out = json.load(open("/b/resp.json"))
            os.remove("/b/resp.ready")
            break
        time.sleep(0.02)
    if out.get("ok"):
        body = base64.b64decode(out.get("body_b64", "")) if out.get("body_b64") else b""
        print("STATUS", out.get("status"))
        print("LEN", len(body))
        print("HEAD", body[:80].decode("utf-8", "replace"))
    else:
        print("ERR", out.get("error"))
    """

    case run_python(script, opts) do
      {:ok, stdout} -> parse_fetch(stdout)
      other -> other
    end
  end

  defp parse_fetch(stdout) do
    lines = String.split(stdout, "\n", trim: true)
    status = grab(lines, "STATUS ")
    cond do
      err = grab(lines, "ERR ") -> {:error, err}
      status -> {:ok, %{status: String.to_integer(status), len: grab(lines, "LEN "), head: grab(lines, "HEAD ")}}
      true -> {:error, {:unparsed, stdout}}
    end
  end

  defp grab(lines, prefix) do
    case Enum.find(lines, &String.starts_with?(&1, prefix)) do
      nil -> nil
      line -> String.replace_prefix(line, prefix, "")
    end
  end

  # ── host watcher: services request-files via the mediated egress broker ──────────────────────────────────
  defp watch_loop(_dir, _opts, _parent, _stop, 0), do: :ok

  defp watch_loop(dir, opts, parent, stop, budget) do
    receive do
      {^stop, :done} -> :ok
    after
      @poll_ms ->
        ready = Path.join(dir, "req.ready")

        if File.exists?(ready) do
          service_one(dir, opts)
          # request consumed; remove markers so the next request is unambiguous
          File.rm(ready)
          File.rm(Path.join(dir, "req.json"))
          watch_loop(dir, opts, parent, stop, budget - 1)
        else
          watch_loop(dir, opts, parent, stop, budget)
        end
    end
  end

  defp service_one(dir, opts) do
    resp =
      with {:ok, raw} <- File.read(Path.join(dir, "req.json")),
           {:ok, req} <- Jason.decode(raw) do
        do_brokered(req, opts)
      else
        _ -> %{"ok" => false, "error" => "bad_request"}
      end

    File.write!(Path.join(dir, "resp.json"), Jason.encode!(resp))
    # write the marker LAST so the guest never reads a half-written resp.json
    File.write!(Path.join(dir, "resp.ready"), "1")
  end

  defp do_brokered(req, opts) do
    method = (req["method"] || "GET") |> String.downcase() |> String.to_atom()
    url = req["url"] || ""
    headers = for {k, v} <- req["headers"] || %{}, do: {to_string(k), to_string(v)}

    body =
      case req["body_b64"] do
        nil -> nil
        b64 -> Base.decode64!(b64)
      end

    # the guest may NOT widen the allow-list — the host's :allow (per-instance scope) is authoritative; a guest
    # "allow" is ignored. SSRF floor + pin + rate + revocation all enforced inside NetGuard.request.
    call_opts =
      [headers: headers, body: body]
      |> put_if(:allow, Keyword.get(opts, :allow))
      |> put_if(:principal, Keyword.get(opts, :principal))
      |> put_if(:rate, Keyword.get(opts, :rate))

    case Workbooks.NetGuard.request(method, url, call_opts) do
      {:ok, %{status: status, body: rbody}} ->
        %{"ok" => true, "status" => status, "body_b64" => Base.encode64(rbody)}

      {:error, reason} ->
        %{"ok" => false, "error" => to_string(reason)}
    end
  end

  defp put_if(kw, _k, nil), do: kw
  defp put_if(kw, k, v), do: Keyword.put(kw, k, v)
end
