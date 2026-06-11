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

  plug(:match)
  plug(:dispatch)

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

  defp check_secret(conn) do
    case System.get_env("WB_GK_SECRET") do
      s when s in [nil, ""] ->
        {:error, 503, "groundskeeper not configured"}

      secret ->
        presented = conn |> Plug.Conn.get_req_header("x-gk-secret") |> List.first() || ""

        if Plug.Crypto.secure_compare(presented, secret),
          do: :ok,
          else: {:error, 403, "forbidden"}
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
