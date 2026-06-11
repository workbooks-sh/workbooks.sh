defmodule Workbooks.Groundskeeper.Router do
  @moduledoc """
  The /gk surface — what the ElevenLabs agent's server tools call. Mounted
  under `Workbooks.Web` (forward "/gk"); `Workbooks.Auth` passes /gk through
  because this router enforces its OWN credential:

  - tool routes require header `x-gk-secret` == WB_GK_SECRET (constant-time;
    503 when unset — fail closed, the surface simply doesn't exist unconfigured)
  - POST /postcall verifies the ElevenLabs webhook HMAC
    (`elevenlabs-signature: t=<ts>,v0=hmac_sha256(secret, "t.body")`) with
    WB_GK_POSTCALL_SECRET, then archives the transcript as a groundwork source.
  """
  use Plug.Router
  alias Workbooks.Groundskeeper

  plug(:cors)
  plug(:match)
  plug(:dispatch)

  # The native workbook shell calls from capacitor://localhost — a cross-origin
  # context with a custom header, so the browser preflights. Open CORS is safe
  # here: every data route still requires the x-gk-secret (or the HMAC).
  defp cors(conn, _opts) do
    conn =
      conn
      |> Plug.Conn.put_resp_header("access-control-allow-origin", "*")
      |> Plug.Conn.put_resp_header("access-control-allow-headers", "x-gk-secret, content-type")
      |> Plug.Conn.put_resp_header("access-control-allow-methods", "GET, POST, OPTIONS")

    if conn.method == "OPTIONS",
      do: conn |> Plug.Conn.send_resp(204, "") |> Plug.Conn.halt(),
      else: conn
  end

  # The app login (wb-3ojf.5): one password on the phone → a signed session
  # cookie; every real secret stays host-side. Token = expiry.hmac(WB_GK_SECRET),
  # so no session store is needed. Gated on WB_GK_APP_PASSWORD (unset → 503).
  post "/login" do
    {:ok, body, conn} = Plug.Conn.read_body(conn)

    with pw when pw not in [nil, ""] <- System.get_env("WB_GK_APP_PASSWORD"),
         %{"password" => presented} <- Jason.decode(body) |> elem(1),
         true <- Plug.Crypto.secure_compare(presented || "", pw) do
      conn
      |> Plug.Conn.put_resp_cookie("gk_session", session_token(),
        max_age: 30 * 24 * 3600,
        http_only: true,
        secure: true,
        same_site: "Lax"
      )
      |> json(200, %{ok: true})
    else
      nil -> json(conn, 503, %{error: "app password not configured"})
      _ -> json(conn, 403, %{error: "wrong password"})
    end
  end

  # The workbook mobile app (wb-3ojf.5) — a single self-contained HTML file.
  # Public shell: it ships no credentials (auth is the login above, or the
  # on-device secret); every data/voice call it makes is gated below.
  get "/app" do
    path = Path.join([Groundskeeper.home(), "app", "groundskeeper.html"])

    case File.read(path) do
      {:ok, html} -> conn |> Plug.Conn.put_resp_content_type("text/html") |> Plug.Conn.send_resp(200, html)
      _ -> json(conn, 404, %{error: "app not installed in gk home"})
    end
  end

  post "/tool/:name" do
    {:ok, body, conn} = Plug.Conn.read_body(conn)

    with :ok <- check_secret(conn) do
      params = if(body == "", do: %{}, else: Jason.decode!(body))

      out =
        case name do
          "repo_state" -> Groundskeeper.repo_state(params["query"] || "summary")
          "capture" -> Groundskeeper.capture(params["text"] || "", params["kind"] || "note")
          "file_issue" -> Groundskeeper.file_issue(params["title"] || "untitled", params["description"] || "")
          "dispatch" -> Groundskeeper.dispatch(params["goal"] || "")
          "tasks" -> Groundskeeper.tasks()
          # the workbook app's voice entry: a short-lived signed conversation
          # URL minted host-side — the API key never reaches the client.
          "signed_url" ->
            case Workbooks.Groundskeeper.ElevenLabs.signed_url() do
              {:ok, url} -> %{signed_url: url}
              {:error, e} -> %{error: inspect(e)}
            end

          _ -> %{error: "unknown tool #{name}"}
        end

      json(conn, 200, out)
    else
      {:error, status, msg} -> json(conn, status, %{error: msg})
    end
  end

  get "/tool/tasks" do
    case check_secret(conn) do
      :ok -> json(conn, 200, Groundskeeper.tasks())
      {:error, status, msg} -> json(conn, status, %{error: msg})
    end
  end

  # ElevenLabs post-call webhook: every finished conversation becomes a
  # groundwork source (sources/<date>-call-<id>/), transcript + metadata.
  post "/postcall" do
    {:ok, body, conn} = Plug.Conn.read_body(conn)

    case verify_postcall(conn, body) do
      :ok ->
        payload = Jason.decode!(body)
        data = payload["data"] || payload
        conv_id = data["conversation_id"] || "unknown"
        dir = Path.join([Groundskeeper.home(), "sources", "#{Date.utc_today()}-call-#{conv_id}"])
        File.mkdir_p!(dir)
        File.write!(Path.join(dir, "postcall.json"), body)

        transcript =
          (data["transcript"] || [])
          |> Enum.map(fn turn -> "#{turn["role"]}: #{turn["message"]}" end)
          |> Enum.join("\n\n")

        File.write!(Path.join(dir, "transcript.txt"), transcript)
        # Reconcile the board after every conversation (wb-3ojf.3) — async,
        # the webhook response never waits on bd/git.
        spawn(fn -> Workbooks.Groundskeeper.Board.sync_and_commit() end)
        json(conn, 200, %{archived: Path.relative_to(dir, Groundskeeper.home())})

      {:error, status, msg} ->
        json(conn, status, %{error: msg})
    end
  end

  match _ do
    json(conn, 404, %{error: "not found"})
  end

  # Two credentials open the tool surface: the shared secret header (the
  # ElevenLabs webhooks) or a valid session cookie (the workbook app, after
  # /login). Fails closed when WB_GK_SECRET is unset.
  defp check_secret(conn) do
    case System.get_env("WB_GK_SECRET") do
      s when s in [nil, ""] ->
        {:error, 503, "groundskeeper not configured"}

      secret ->
        presented = conn |> Plug.Conn.get_req_header("x-gk-secret") |> List.first() || ""

        cond do
          Plug.Crypto.secure_compare(presented, secret) -> :ok
          valid_session?(conn) -> :ok
          true -> {:error, 403, "forbidden"}
        end
    end
  end

  defp session_token do
    expiry = System.system_time(:second) + 30 * 24 * 3600
    "#{expiry}.#{session_sig(expiry)}"
  end

  defp session_sig(expiry) do
    :crypto.mac(:hmac, :sha256, System.get_env("WB_GK_SECRET") || "", "gk-session:#{expiry}")
    |> Base.url_encode64(padding: false)
  end

  defp valid_session?(conn) do
    with %{"gk_session" => token} <- Plug.Conn.fetch_cookies(conn).req_cookies,
         [ts, sig] <- String.split(token, ".", parts: 2),
         {expiry, ""} <- Integer.parse(ts),
         true <- expiry > System.system_time(:second) do
      Plug.Crypto.secure_compare(sig, session_sig(expiry))
    else
      _ -> false
    end
  end

  defp verify_postcall(conn, body) do
    case System.get_env("WB_GK_POSTCALL_SECRET") do
      s when s in [nil, ""] ->
        {:error, 503, "postcall not configured"}

      secret ->
        header = conn |> Plug.Conn.get_req_header("elevenlabs-signature") |> List.first() || ""

        with %{"t" => t, "v0" => v0} <- parse_signature(header),
             mac = :crypto.mac(:hmac, :sha256, secret, "#{t}.#{body}") |> Base.encode16(case: :lower),
             true <- Plug.Crypto.secure_compare(v0, mac) do
          :ok
        else
          _ -> {:error, 403, "bad signature"}
        end
    end
  end

  defp parse_signature(header) do
    header
    |> String.split(",")
    |> Enum.flat_map(fn part ->
      case String.split(part, "=", parts: 2) do
        [k, v] -> [{k, v}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  defp json(conn, status, data) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(data))
  end
end
