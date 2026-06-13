defmodule Workbooks.PyNet do
  @moduledoc """
  wb-broker PYTHON BROKERED-TRANSPORT — gives a wasip1 runtime (CPython 3.12 today; any wasip1 runtime with file I/O) SSRF-safe outbound
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
  # safety ceiling so a wedged guest can't spin the watcher forever (bounds total serviced requests)
  @default_max_requests 64

  @doc """
  GENERIC broker transport (language-agnostic): preopen a fresh broker dir, spawn the concurrent host watcher
  (which services net + exec request-files via the SAME mediated brokers), and invoke `run_fn` with the dirs to
  preopen (the broker dir at `:mount`, default `/b`, ahead of any caller `:dirs`). `run_fn.(dirs)` runs the
  guest however it likes (a registered command, a built wasm) and returns `{:ok, out, status}` | `{:error, _}`.
  Any wasip1 guest with file I/O (CPython, a clang-built C tool, …) can use the file protocol — the transport
  is not Python-specific. The watcher is torn down + the dir removed when `run_fn` returns.
  """
  def with_broker(opts, run_fn) when is_function(run_fn, 1) do
    mount = Keyword.get(opts, :mount, "/b")
    bdir = Path.join(System.tmp_dir!(), "wbroker_#{System.unique_integer([:positive])}")
    File.mkdir_p!(bdir)

    parent = self()
    stop = make_ref()
    max_req = Keyword.get(opts, :max_requests, @default_max_requests)
    watcher = spawn_link(fn -> watch_loop(bdir, opts, parent, stop, max_req) end)
    dirs = ["#{bdir}::#{mount}" | Keyword.get(opts, :dirs, [])]

    try do
      run_fn.(dirs)
    after
      send(watcher, {stop, :done})
      File.rm_rf(bdir)
    end
  end

  @doc """
  Run a built wasm tool (a `.wasm` path, e.g. a clang/mrustc-compiled C/Rust CLI) with the brokered transport
  mounted — so a STANDARD compiled tool gets brokered net + exec via the file protocol (+ a small guest shim),
  no Python involved. `{:ok, out, status}` | `{:error, _}`.
  """
  def run_wasm(wasm_path, stdin, argv, opts \\ []) when is_binary(wasm_path) and is_list(argv) do
    with_broker(opts, fn dirs ->
      case Workbooks.PackageManager.run(wasm_path, stdin, argv, dirs, with_status: true) do
        {out, status} when is_binary(out) -> {:ok, out, status}
        out when is_binary(out) -> {:ok, out, 0}
        other -> {:error, {:run_failed, other}}
      end
    end)
  end

  @doc "Run CPython `script` (`-c`) with the brokered transport mounted at `/b`. `{:ok, out, status}`."
  def run_python(script, opts \\ []) when is_binary(script) do
    stdin = Keyword.get(opts, :stdin, "")
    argv = Keyword.get(opts, :argv, [])

    with_broker(opts, fn dirs ->
      # `python -c <script> <argv...>` exposes argv to the tool as sys.argv[1:]; stdin is the tool's input.
      # run_status preserves the guest's EXIT CODE — a tool that errors (e.g. SSRF-denied request -> URLError ->
      # sys.exit(1)) must report non-zero, not be flattened to success.
      case Workbooks.CommandRegistry.run_status("python", stdin, ["-c", script | argv], dirs) do
        {:ok, body, status} when is_binary(body) -> {:ok, body, status}
        {:ok, body} when is_binary(body) -> {:ok, body, 0}
        body when is_binary(body) -> {:ok, body, 0}
        other -> {:error, {:run_failed, other}}
      end
    end)
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
      {:ok, stdout, _status} -> parse_fetch(stdout)
      other -> other
    end
  end

  @doc """
  Run a user Python `script` with a urllib ADAPTER injected — `urllib.request.urlopen(...)` is transparently
  rerouted through the brokered file protocol, so UNMODIFIED Python HTTP code (and anything built on urllib)
  runs SSRF-safe via the host with no source changes. Same opts/cadence as `run_python/2`.
  """
  def run_python_urllib(script, opts \\ []) when is_binary(script) do
    case run_python(urllib_prelude() <> "\n" <> script, opts) do
      {:ok, out, _status} -> {:ok, out}
      other -> other
    end
  end

  @doc """
  Run a registered Python net TOOL (a `:pynet` command): the urllib/requests-adapted `script` with `stdin` and
  `argv` (exposed as `sys.stdin` / `sys.argv[1:]`). This is the per-tool LIVE path for the Python net-tool
  class — a brokered network CLI is a first-class command with no wasip2 build. Returns `{:ok, out, status}`
  (the guest's EXIT CODE preserved) | `{:error, _}`.
  """
  def run_tool(script, stdin, argv, opts \\ []) when is_binary(script) and is_list(argv) do
    run_python(urllib_prelude() <> "\n" <> script, Keyword.merge(opts, stdin: stdin, argv: argv))
  end

  # injected once at the top of the guest program: replaces urllib.request.urlopen with a brokered client that
  # speaks the /b file protocol. Returns a BytesIO subclass so .read()/.status/.getcode()/.headers behave like a
  # real http.client.HTTPResponse for the common cases.
  defp urllib_prelude do
    ~S"""
    import json as _wbj, os as _wbos, time as _wbt, base64 as _wbb, io as _wbio
    import urllib.request as _wbreq, urllib.error as _wberr

    class _WBResp(_wbio.BytesIO):
        pass

    def _wb_urlopen(url, data=None, timeout=None, *a, **k):
        if isinstance(url, _wbreq.Request):
            full = url.full_url; method = url.get_method()
            hdrs = {str(x): str(y) for x, y in url.header_items()}
            data = url.data if url.data is not None else data
        else:
            full = url; hdrs = {}; method = "POST" if data is not None else "GET"
        payload = {"method": method, "url": full, "headers": hdrs}
        if data is not None:
            if isinstance(data, str): data = data.encode()
            payload["body_b64"] = _wbb.b64encode(data).decode()
            if payload["method"] == "GET": payload["method"] = "POST"
        open("/b/req.json", "w").write(_wbj.dumps(payload))
        open("/b/req.ready", "w").write("1")
        out = {"ok": False, "error": "timeout"}
        for _ in range(1500):
            if _wbos.path.exists("/b/resp.ready"):
                out = _wbj.load(open("/b/resp.json")); _wbos.remove("/b/resp.ready"); break
            _wbt.sleep(0.02)
        if not out.get("ok"):
            raise _wberr.URLError(out.get("error", "brokered request failed"))
        body = _wbb.b64decode(out.get("body_b64", "")) if out.get("body_b64") else b""
        r = _WBResp(body)
        r.status = out.get("status"); r.code = out.get("status")
        r.getcode = lambda: out.get("status"); r.headers = {}; r.url = full
        return r

    _wbreq.urlopen = _wb_urlopen

    # `requests` shim — this CPython has no `requests` package, so register a minimal one built on the brokered
    # urlopen. Covers the common get/post/put/delete + Response.status_code/.text/.json()/.content the bulk of
    # net tools use. Everything flows through _wb_urlopen, so the full SSRF/allow-list cadence applies.
    import sys as _wbsys, types as _wbtypes
    _wbrequests = _wbtypes.ModuleType("requests")

    class _WBRResp:
        def __init__(self, status, body, url):
            self.status_code = status; self.content = body; self.url = url
            self.text = body.decode("utf-8", "replace"); self.headers = {}
        def json(self): return _wbj.loads(self.text)
        def raise_for_status(self):
            if self.status_code and self.status_code >= 400:
                raise Exception("HTTP %d" % self.status_code)

    def _wb_rrequest(method, url, data=None, json=None, headers=None, params=None, **k):
        if params:
            from urllib.parse import urlencode as _ue
            url = url + ("&" if "?" in url else "?") + _ue(params)
        if json is not None:
            data = _wbj.dumps(json).encode()
            headers = dict(headers or {}); headers.setdefault("Content-Type", "application/json")
        if isinstance(data, str): data = data.encode()
        req = _wbreq.Request(url, data=data, method=method.upper(), headers=headers or {})
        r = _wb_urlopen(req)
        return _WBRResp(r.status, r.read(), url)

    _wbrequests.request = _wb_rrequest
    _wbrequests.get = lambda url, **k: _wb_rrequest("GET", url, **k)
    _wbrequests.post = lambda url, **k: _wb_rrequest("POST", url, **k)
    _wbrequests.put = lambda url, **k: _wb_rrequest("PUT", url, **k)
    _wbrequests.delete = lambda url, **k: _wb_rrequest("DELETE", url, **k)
    _wbrequests.head = lambda url, **k: _wb_rrequest("HEAD", url, **k)
    _wbsys.modules["requests"] = _wbrequests

    # subprocess shim — wasip1 has no fork/exec, so route subprocess.run/check_output through the brokered exec
    # (host runs a REGISTERED wasm command via ExecBroker; default-deny + no shell/injection). A Python tool can
    # orchestrate brokered commands (build-driver/pipx class) but can't escape to a host shell.
    import subprocess as _wbsub

    def _wb_exec(name, argv=None, stdin=b""):
        if isinstance(stdin, str): stdin = stdin.encode()
        payload = {"kind": "exec", "name": name, "argv": [str(a) for a in (argv or [])]}
        if stdin: payload["stdin_b64"] = _wbb.b64encode(stdin).decode()
        open("/b/req.json", "w").write(_wbj.dumps(payload))
        open("/b/req.ready", "w").write("1")
        out = {"ok": False, "error": "timeout"}
        for _ in range(1500):
            if _wbos.path.exists("/b/resp.ready"):
                out = _wbj.load(open("/b/resp.json")); _wbos.remove("/b/resp.ready"); break
            _wbt.sleep(0.02)
        if not out.get("ok"):
            raise _wbsub.SubprocessError("brokered exec denied: %s" % out.get("error"))
        return _wbb.b64decode(out.get("stdout_b64", "")) if out.get("stdout_b64") else b""

    class _WBCompleted:
        def __init__(self, args, returncode, stdout, stderr=b""):
            self.args = args; self.returncode = returncode; self.stdout = stdout; self.stderr = stderr
        def check_returncode(self):
            if self.returncode:
                raise _wbsub.CalledProcessError(self.returncode, self.args, self.stdout, self.stderr)

    def _wb_run(argv, input=None, capture_output=False, text=False, check=False, **k):
        if isinstance(argv, str): argv = [argv]
        data = input if input is not None else b""
        try:
            out = _wb_exec(argv[0], argv[1:], data); rc = 0
        except _wbsub.SubprocessError:
            out = b""; rc = 1
        if text and isinstance(out, (bytes, bytearray)): out = out.decode("utf-8", "replace")
        cp = _WBCompleted(argv, rc, out)
        if check: cp.check_returncode()
        return cp

    def _wb_check_output(argv, input=b"", text=False, **k):
        if isinstance(argv, str): argv = [argv]
        out = _wb_exec(argv[0], argv[1:], input)
        return out.decode("utf-8", "replace") if text else out

    _wbsub.run = _wb_run
    _wbsub.check_output = _wb_check_output
    """
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

  # EXEC dispatch (exec->CommandRegistry stone, Python lane): a guest's subprocess call routes here. The exec
  # runs through ExecBroker — default-deny, REGISTERED-commands-only, no shell/injection, output-capped, depth +
  # concurrency bounded. So a Python tool can ORCHESTRATE brokered wasm commands (the build-driver/pipx class)
  # but can NEVER escape to a host shell or run an arbitrary binary. exec is OFF unless the host grants
  # :exec_allow; :commands scopes WHICH commands (default :all of the registry).
  defp do_brokered(%{"kind" => "exec"} = req, opts) do
    name = req["name"] || ""
    argv = for a <- req["argv"] || [], do: to_string(a)
    stdin = case req["stdin_b64"] do nil -> ""; b64 -> Base.decode64!(b64) end

    # FORK-BOMB DEPTH: each PyNet->exec hop is one level DEEPER than the tool that issued it. Always increment
    # (default base 0) so a chain of orchestrators that exec each other (or one that execs itself) advances
    # toward ExecBroker's @max_depth and is bounded — never an unbounded recursion via the file-exec channel.
    call_opts =
      [allow: Keyword.get(opts, :exec_allow, false), depth: (Keyword.get(opts, :depth) || 0) + 1]
      |> put_if(:commands, Keyword.get(opts, :commands))
      |> put_if(:principal, Keyword.get(opts, :principal))

    case Workbooks.ExecBroker.exec(name, argv, stdin, call_opts) do
      {:ok, out} -> %{"ok" => true, "stdout_b64" => Base.encode64(out), "status" => 0}
      {:error, reason} -> %{"ok" => false, "error" => exec_reason(reason)}
    end
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
      |> put_if(:max_bytes, Keyword.get(opts, :max_bytes))

    case Workbooks.NetGuard.request(method, url, call_opts) do
      {:ok, %{status: status, body: rbody}} ->
        %{"ok" => true, "status" => status, "body_b64" => Base.encode64(rbody)}

      {:error, reason} ->
        %{"ok" => false, "error" => to_string(reason)}
    end
  end

  defp put_if(kw, _k, nil), do: kw
  defp put_if(kw, k, v), do: Keyword.put(kw, k, v)

  defp exec_reason({:command_failed, r}), do: "command_failed:#{inspect(r)}"
  defp exec_reason(r), do: to_string(r)
end
