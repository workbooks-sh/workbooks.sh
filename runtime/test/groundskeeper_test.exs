defmodule GroundskeeperTest do
  @moduledoc """
  The groundskeeper bridge (wb-3ojf): tool auth fails closed, captures land as
  org sources, the spawn lane authors→validates→runs workflows on the task
  ledger (with crash → blocked, the autopoet lesson), and the post-call
  webhook verifies the ElevenLabs HMAC before archiving a transcript.

  All LLM/author calls are injected — no network.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Workbooks.Groundskeeper
  alias Workbooks.Groundskeeper.Tasks

  @secret "gk-test-secret"

  setup do
    home = Path.join(System.tmp_dir!(), "gk-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    System.put_env("WB_GK_HOME", home)
    System.put_env("WB_GK_SECRET", @secret)
    start_supervised!(Tasks)

    on_exit(fn ->
      System.delete_env("WB_GK_HOME")
      System.delete_env("WB_GK_SECRET")
      System.delete_env("WB_GK_POSTCALL_SECRET")
      File.rm_rf!(home)
    end)

    {:ok, home: home}
  end

  defp call(method, path, body \\ nil, headers \\ []) do
    c =
      if body,
        do: conn(method, path, Jason.encode!(body)) |> put_req_header("content-type", "application/json"),
        else: conn(method, path)

    c = Enum.reduce(headers, c, fn {k, v}, acc -> put_req_header(acc, k, v) end)
    Workbooks.Groundskeeper.Router.call(c, Workbooks.Groundskeeper.Router.init([]))
  end

  # ── auth: fail closed ────────────────────────────────────────────────────────

  test "tool route without secret header is forbidden" do
    assert call(:post, "/tool/repo_state", %{}).status == 403
  end

  test "tool route with wrong secret is forbidden" do
    assert call(:post, "/tool/tasks", %{}, [{"x-gk-secret", "nope"}]).status == 403
  end

  test "unconfigured surface (no WB_GK_SECRET) is 503, not open" do
    System.delete_env("WB_GK_SECRET")
    assert call(:post, "/tool/tasks", %{}, [{"x-gk-secret", ""}]).status == 503
  end

  # ── capture ─────────────────────────────────────────────────────────────────

  test "capture appends an org entry to today's capture file", %{home: home} do
    resp = call(:post, "/tool/capture", %{text: "the workbook IS the container", kind: "idea"}, [{"x-gk-secret", @secret}])
    assert resp.status == 200

    file = Path.join([home, "sources", "captures", "#{Date.utc_today()}.org"])
    content = File.read!(file)
    assert content =~ "* idea ["
    assert content =~ "the workbook IS the container"
  end

  # ── the spawn lane ──────────────────────────────────────────────────────────

  @outline """
  #+TITLE: investigate widget pricing
  * TODO Gather sources
    Find three pricing pages. Write scratch/sources.org.
  * TODO Report
    Consolidate into scratch/REPORT.org.
  """

  test "dispatch authors, persists, runs, and feeds back", %{home: home} do
    out =
      Groundskeeper.dispatch("investigate widget pricing",
        author: fn _goal -> {:ok, @outline} end,
        run: fn _task -> {:ok, "done"} end
      )

    assert %{dispatched: true, task: id, workflow: wf} = out
    assert File.exists?(Path.join(home, wf))

    # the run is async; wait for the ledger to settle
    assert eventually(fn ->
             Enum.find(Tasks.list(), &(&1.id == id && &1.status == "done"))
           end)

    # completion queued as feedback exactly once
    feedback = Tasks.drain_feedback()
    assert Enum.any?(feedback, &(&1.task == id and &1.status == "done"))
    assert Tasks.drain_feedback() == []

    # TASKS.md is the rendered, git-visible view
    tasks_md = File.read!(Path.join(home, "TASKS.md"))
    assert tasks_md =~ "### DONE investigate widget pricing"
  end

  test "an invalid outline from the author is rejected, not run" do
    out =
      Groundskeeper.dispatch("bad goal",
        author: fn _ -> {:ok, "just prose, no headings"} end
      )

    assert %{dispatched: false} = out
    assert Tasks.list() == []
  end

  test "a crashing workflow becomes blocked, never stuck doing" do
    out =
      Groundskeeper.dispatch("crash me",
        author: fn _ -> {:ok, @outline} end,
        run: fn _ -> raise "boom" end
      )

    assert %{dispatched: true, task: id} = out

    assert eventually(fn ->
             Enum.find(Tasks.list(), &(&1.id == id && &1.status == "blocked"))
           end)
  end

  # ── post-call webhook ───────────────────────────────────────────────────────

  test "postcall verifies the ElevenLabs HMAC and archives the transcript", %{home: home} do
    System.put_env("WB_GK_POSTCALL_SECRET", "pc-secret")

    payload =
      Jason.encode!(%{
        data: %{
          conversation_id: "conv123",
          transcript: [
            %{role: "user", message: "what's the state of the project?"},
            %{role: "agent", message: "three issues open. the grounds are kept."}
          ]
        }
      })

    t = "1718000000"
    mac = :crypto.mac(:hmac, :sha256, "pc-secret", "#{t}.#{payload}") |> Base.encode16(case: :lower)

    c =
      conn(:post, "/postcall", payload)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("elevenlabs-signature", "t=#{t},v0=#{mac}")
      |> Workbooks.Groundskeeper.Router.call(Workbooks.Groundskeeper.Router.init([]))

    assert c.status == 200

    dir = Path.join([home, "sources", "#{Date.utc_today()}-call-conv123"])
    assert File.read!(Path.join(dir, "transcript.txt")) =~ "the grounds are kept"
  end

  test "postcall with a bad signature is rejected" do
    System.put_env("WB_GK_POSTCALL_SECRET", "pc-secret")

    c =
      conn(:post, "/postcall", "{}")
      |> put_req_header("elevenlabs-signature", "t=1,v0=deadbeef")
      |> Workbooks.Groundskeeper.Router.call(Workbooks.Groundskeeper.Router.init([]))

    assert c.status == 403
  end

  test "boot marks orphaned active ledger entries BLOCKED", %{home: home} do
    stop_supervised!(Tasks)
    File.write!(Path.join(home, "TASKS.md"), "States: TODO DOING BLOCKED | DONE\n\n### DOING orphaned run\n### DONE finished run\n")
    start_supervised!(Tasks)

    content = File.read!(Path.join(home, "TASKS.md"))
    assert content =~ "### BLOCKED orphaned run"
    assert content =~ "### DONE finished run"
  end

  # ── the app password gate ───────────────────────────────────────────────────

  test "login with the right password sets a session cookie that opens the tools" do
    System.put_env("WB_GK_APP_PASSWORD", "open-sesame")
    on_exit(fn -> System.delete_env("WB_GK_APP_PASSWORD") end)

    login = call(:post, "/login", %{password: "open-sesame"})
    assert login.status == 200
    %{"gk_session" => %{value: token}} = login.resp_cookies

    c =
      conn(:post, "/tool/tasks", "{}")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("cookie", "gk_session=#{token}")
      |> Workbooks.Groundskeeper.Router.call(Workbooks.Groundskeeper.Router.init([]))

    assert c.status == 200
  end

  test "wrong password is 403; unconfigured password is 503; forged cookie fails" do
    assert call(:post, "/login", %{password: "x"}).status == 503

    System.put_env("WB_GK_APP_PASSWORD", "open-sesame")
    on_exit(fn -> System.delete_env("WB_GK_APP_PASSWORD") end)
    assert call(:post, "/login", %{password: "nope"}).status == 403

    forged = "#{System.system_time(:second) + 1000}.deadbeef"

    c =
      conn(:post, "/tool/tasks", "{}")
      |> put_req_header("cookie", "gk_session=#{forged}")
      |> Workbooks.Groundskeeper.Router.call(Workbooks.Groundskeeper.Router.init([]))

    assert c.status == 403
  end

  # ── the workbook app ────────────────────────────────────────────────────────

  test "GET /app serves the workbook shell without any secret", %{home: home} do
    File.mkdir_p!(Path.join(home, "app"))
    File.write!(Path.join([home, "app", "groundskeeper.html"]), "<!doctype html><title>gk</title>")

    c = conn(:get, "/app") |> Workbooks.Groundskeeper.Router.call(Workbooks.Groundskeeper.Router.init([]))
    assert c.status == 200
    assert c.resp_body =~ "gk"
  end

  test "signed_url tool is secret-gated like every other tool" do
    assert call(:post, "/tool/signed_url", %{}).status == 403
  end

  # ── the board ───────────────────────────────────────────────────────────────

  test "board sync renders BOARD.md from bd json (stubbed bd)", %{home: home} do
    bin = Path.join(home, "bin")
    File.mkdir_p!(bin)

    issues =
      Jason.encode!([
        %{id: "wb-1", title: "open thing", status: "open", priority: 1, issue_type: "task", updated_at: "2", closed_at: nil},
        %{id: "wb-2", title: "doing thing", status: "in_progress", priority: 1, issue_type: "epic", updated_at: "1", closed_at: nil},
        %{id: "wb-3", title: "done thing", status: "closed", priority: 2, issue_type: "task", updated_at: "1", closed_at: "3"}
      ])

    File.write!(Path.join(bin, "bd"), "#!/bin/sh\ncat <<'EOF'\n#{issues}\nEOF\n")
    File.chmod!(Path.join(bin, "bd"), 0o755)
    original_path = System.get_env("PATH")
    System.put_env("PATH", "#{bin}:#{original_path}")
    on_exit(fn -> System.put_env("PATH", original_path) end)

    assert {:ok, path} = Workbooks.Groundskeeper.Board.sync()
    board = File.read!(path)
    assert board =~ "- **TODO** open thing"
    assert board =~ "- **DOING** doing thing (epic)"
    assert board =~ "- **DONE** done thing"
    assert board =~ "NEVER hand-edit"
  end

  # ── plumbing ────────────────────────────────────────────────────────────────

  defp eventually(fun, tries \\ 50) do
    case fun.() do
      nil when tries > 0 ->
        Process.sleep(100)
        eventually(fun, tries - 1)

      nil -> false
      falsy when falsy == false -> false
      result -> result
    end
  end
end
