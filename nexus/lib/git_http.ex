defmodule Nexus.GitHttp do
  @moduledoc """
  Git smart-HTTP transport — the nexus AS a git remote. A workspace is a bare repo you `git push` to:

      git push https://x:<wbk_PAT>@<nexus>/git/<workspace>.git main

  We shell to the standard `git http-backend` (CGI) rather than hand-rolling the pack protocol.
  Auth is HTTP Basic with a `wbk_` PAT as the password (git clients speak Basic, not Bearer) — verified
  via `Nexus.Auth.Token`; the resolved tenant scopes the repo. On push, `Nexus.Git`'s post-receive hook
  checks the files out into `WB_DATA/<workspace>` so `/cloud/tree` shows them live.

  Generic mechanism: any consumer with our CLI (or plain git) can push; no Workbooks business here.

  ## Authorization boundary (intentional — wb-inqj)

  The git transport enforces ORG-level access, not per-workspace visibility:
    * cross-org is impossible (`authorize/3` — a token may only touch its own org's repos, fix wb-d3vh);
    * commit signatures bind authorship at push (`Nexus.Git.sig_gate` under the `:hard` policy, wb-i2c8);
    * BUT an authenticated org member may `git clone` ANY of the org's repos — the per-workspace
      draft/private visibility (`Nexus.Authz.may_access?`) is enforced at the CLOUD layer
      (`/cloud/tree`, `file_read`), NOT here. This is the one-nexus-per-org read model: members read org
      repos. Honoring per-workspace visibility on the git read path would require the cloud to supply a
      visibility map to this GENERIC transport (THE LINE) — deferred unless a deployment needs it.
  """
  import Plug.Conn
  require Logger

  @doc "Bare repos live on the volume (`Nexus.Paths.repos_root/0`); working trees at `Nexus.Paths.work_dir/1`."
  defdelegate repos_root, to: Nexus.Paths
  defdelegate work_dir(name), to: Nexus.Paths

  @doc "Handle a `/git/<rest>` request. `rest` is the path AFTER `/git/` (e.g. `demo.git/info/refs`)."
  def handle(conn, rest) do
    case authed(conn) do
      {:ok, ident} ->
        serve(conn, rest, ident)

      :error ->
        conn
        |> put_resp_header("www-authenticate", ~s(Basic realm="Workbooks"))
        |> send_resp(401, "git authentication required (use a wbk_ token as the password)")
    end
  end

  # Git push follows the deploy block's AUTH MODE (Part A). When auth is TRUSTED (`Nexus.Auth.None` —
  # the default / a `deploy do auth="trusted" end` workbook, incl. the local vfkit dev nexus), a push
  # needs no PAT and is scoped to the default tenant — so `work deploy <dir> --nexus local` just works.
  # When the workbook declares a real auth mode (bearer/jwt), a valid `wbk_` token is still required, so
  # auth-gated behavior is tested faithfully against what cloud enforces.
  defp authed(conn) do
    if Nexus.Auth.adapter() == Nexus.Auth.None do
      {:ok, %{tenant: Nexus.Store.default_tenant(), user: "local", scopes: [], roles: []}}
    else
      with ["Basic " <> b64] <- get_req_header(conn, "authorization"),
           {:ok, decoded} <- Base.decode64(b64),
           [_user, pass] <- String.split(decoded, ":", parts: 2),
           {:ok, ident} <- resolve_pat(pass) do
        {:ok, ident}
      else
        _ -> :error
      end
    end
  end

  # Resolve a `wbk_` personal-access token to an identity, accepting BOTH token systems so the SAME token
  # a user mints in the dashboard (`Nexus.ControlPlane.Token`, also what `Nexus.Auth.Cloud` accepts as the
  # CLI Bearer on /api/platform) authenticates a git push here — one credential for the whole customer
  # protocol (mint in dashboard → `work`/git push → hot-reload). Falls back to `Nexus.Auth.Token` for the
  # runtime's own tenant-scoped tokens. Order: control-plane (the user-facing mint) first.
  @doc false
  # Test seam — the PAT→identity resolution that gates a git push (accepts both token systems).
  def resolve_pat_for_test(pass), do: resolve_pat(pass)

  defp resolve_pat(pass) do
    case Nexus.ControlPlane.Token.resolve(pass) do
      {:ok, %{org: org} = rec} -> {:ok, %{tenant: org, user: rec.user || "cli", scopes: ["api"], roles: List.wrap(rec.role)}}
      _ -> Nexus.Auth.Token.verify(pass)
    end
  end

  @doc """
  Parse the workspace id out of a `/git/<rest>` path. The id IS the on-disk folder path AND the git
  remote, so NESTED ids must survive (e.g. `site/lander.git/info/refs` → `"site/lander"`, not the
  first segment). Fails closed (`:error`) on traversal / empty / leading-slash / dot segments.
  """
  @spec workspace_from_path(String.t()) :: {:ok, String.t()} | :error
  def workspace_from_path(rest) when is_binary(rest) do
    ws = rest |> String.split(".git", parts: 2) |> hd()
    segs = String.split(ws, "/")

    cond do
      ws == "" -> :error
      String.starts_with?(ws, "/") -> :error
      Enum.any?(segs, &(&1 in ["", ".", ".."])) -> :error
      true -> {:ok, ws}
    end
  end

  def workspace_from_path(_), do: :error

  @doc """
  This nexus's OWN org (machine identity) — the CANONICAL `Nexus.Auth.nexus_org/0`: `NEXUS_TENANT` pin,
  else the founding owner's org, else default. (Was `NEXUS_TENANT || default`; with NEXUS_TENANT unset
  that's `"default"`, which no real-org PAT matches, so the gate 403'd EVERY content push — wb-5wsg.)
  """
  def nexus_org, do: Nexus.Auth.nexus_org()

  @doc """
  May `ident` touch THIS nexus's repos? (fix wb-d3vh) On a multi-tenant nexus a token may only act on
  its OWN org's repos — its `tenant` must equal `nexus_org`; a foreign-org (or public/default) token is
  rejected. Single-tenant/local (auth=None, `multi?`=false) is always allowed (one default tenant).
  """
  def authorize(ident, multi?, nexus_org), do: not multi? or ident[:tenant] == nexus_org

  defp serve(conn, rest, ident) do
    cond do
      match?(:error, workspace_from_path(rest)) ->
        send_resp(conn, 400, "bad workspace name")

      # Bind the request to this nexus's org (fix wb-d3vh): a foreign-org token can never reach our repos
      # — the tenant comes from the resolved PAT, not the URL, so cross-org read/write is impossible.
      not authorize(ident, Nexus.Auth.multi?(), nexus_org()) ->
        send_resp(conn, 403, "not authorized for this nexus's organization")

      true ->
        {:ok, ws} = workspace_from_path(rest)
        bare = Nexus.Git.bare_path(repos_root(), ws)
        {:ok, _} = Nexus.Git.provision_remote(bare, work_dir(ws))

        {:ok, body, conn} = read_body(conn, length: 200_000_000, read_length: 1_000_000)
        {out, _exit} = run_backend(body, cgi_env(conn, rest, ident, body))
        resp = relay(conn, out)

        # After a push (receive-pack), refresh the compiled tier so pushed units serve — files are
        # already live on disk via the post-receive checkout. Async: don't block the git response.
        if String.contains?(rest, "git-receive-pack") and conn.method == "POST" do
          Task.start(fn ->
            if function_exported?(Nexus.Server, :remount, 0), do: Nexus.Server.remount()
            # jj-as-substrate: fold the externally-pushed commits into the op-log (no-op unless on).
            if Nexus.JJ.substrate?(), do: Nexus.JJ.import_refs(bare, work_dir(ws))
          end)
        end

        resp
    end
  end

  defp cgi_env(conn, rest, ident, body) do
    [
      {"GIT_PROJECT_ROOT", repos_root()},
      {"GIT_HTTP_EXPORT_ALL", "1"},
      {"PATH_INFO", "/" <> rest},
      {"REQUEST_METHOD", conn.method},
      {"QUERY_STRING", conn.query_string || ""},
      {"CONTENT_TYPE", header(conn, "content-type")},
      {"CONTENT_LENGTH", Integer.to_string(byte_size(body))},
      {"REMOTE_USER", to_string(ident[:user] || "")},
      {"REMOTE_ADDR", "127.0.0.1"},
      {"GIT_PROTOCOL", header(conn, "git-protocol")}
    ]
  end

  defp header(conn, name) do
    case get_req_header(conn, name) do
      [v | _] -> v
      _ -> ""
    end
  end

  # Run `git http-backend` as CGI. CONTENT_LENGTH is set, so it reads exactly the body off stdin and
  # never blocks on EOF. We collect stdout until the process exits.
  defp run_backend(body, env) do
    git = System.find_executable("git") || "git"
    env_cl = Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v || "")} end)

    port =
      Port.open({:spawn_executable, git}, [
        :binary, :exit_status, :use_stdio, :hide,
        args: ["http-backend"],
        env: env_cl
      ])

    if byte_size(body) > 0, do: Port.command(port, body)
    collect(port, [])
  end

  # Generous timeout: the pre-receive COMPILE GATE boots an isolated `bin/nexus eval` to compile-check
  # the pushed tree, which legitimately takes longer than a plain push. Too short → a real push
  # false-fails by timeout. 180s covers a cold eval + compile; a genuinely hung backend still bails.
  @backend_timeout 180_000

  defp collect(port, acc) do
    receive do
      {^port, {:data, d}} -> collect(port, [acc | d])
      {^port, {:exit_status, s}} -> {IO.iodata_to_binary(acc), s}
    after
      @backend_timeout ->
        try do Port.close(port) catch _, _ -> :ok end
        {IO.iodata_to_binary(acc), 1}
    end
  end

  # Split the CGI response (headers \r\n\r\n body), pass headers + status through to the client.
  defp relay(conn, out) do
    {head, rest} =
      case :binary.split(out, "\r\n\r\n") do
        [h, b] -> {h, b}
        _ -> case :binary.split(out, "\n\n") do
               [h, b] -> {h, b}
               _ -> {"", out}
             end
      end

    headers =
      head
      |> String.split(~r/\r?\n/, trim: true)
      |> Enum.flat_map(fn line ->
        case String.split(line, ":", parts: 2) do
          [k, v] -> [{String.downcase(String.trim(k)), String.trim(v)}]
          _ -> []
        end
      end)

    {status, headers} =
      case List.keytake(headers, "status", 0) do
        {{_, v}, rest} -> {v |> String.slice(0, 3) |> String.to_integer(), rest}
        nil -> {200, headers}
      end

    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_resp_header(c, k, v) end)
    send_resp(conn, status, rest)
  end
end
