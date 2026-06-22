defmodule Nexus.AgentTokensTest do
  @moduledoc """
  RED tests for wb-r0zy: `Nexus.Agent.run/1`'s OK result must carry `tokens: tel.total` — the token
  total for THIS run, read from the run's own telemetry accumulator, not from
  `Nexus.Telemetry.runs(agent) |> hd` (which is keyed by AGENT, so concurrent/interleaved runs of the
  same agent attribute each other's tokens).

  These drive a real `run/1` against a LOCAL OpenAI-compatible stub (Bandit — the project's HTTP
  server; no network, no LLM key): the stub returns one no-tool-call completion with a known
  `usage.total_tokens`, so the loop ends in one turn and the result must report that exact token count.
  """
  use ExUnit.Case, async: false

  # A tiny chat/completions stub. Each request pops the next reply (token count) from an Agent queue,
  # so interleaved runs can be given distinct totals and we can prove per-run attribution.
  defmodule Stub do
    @moduledoc false
    use Plug.Router
    plug(:match)
    plug(:dispatch)

    # Grab a free OS port, then bind Bandit to it (small race window, fine for tests). The reply queue
    # is keyed by port in :persistent_term so the route finds it via conn.port (no Plug.Router opts plumbing).
    def start(queue) do
      {:ok, ls} = :gen_tcp.listen(0, [])
      {:ok, port} = :inet.port(ls)
      :gen_tcp.close(ls)
      :persistent_term.put({__MODULE__, port}, queue)
      {:ok, pid} = Bandit.start_link(plug: __MODULE__, port: port, startup_log: false)
      {port, pid}
    end

    post "/v1/chat/completions" do
      queue = :persistent_term.get({__MODULE__, conn.port})
      total = Agent.get_and_update(queue, fn [h | t] -> {h, t} end)

      resp = %{
        "choices" => [
          %{"message" => %{"content" => "done", "tool_calls" => []}, "finish_reason" => "stop"}
        ],
        "usage" => %{"prompt_tokens" => 0, "completion_tokens" => total, "total_tokens" => total}
      }

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(resp))
    end

    match _ do
      send_resp(conn, 404, "no")
    end
  end

  setup do
    Application.ensure_all_started(:bandit)
    {:ok, q} = Agent.start_link(fn -> [] end)
    {port, pid} = Stub.start(q)
    base = "http://127.0.0.1:#{port}/v1/chat/completions"
    on_exit(fn -> Process.exit(pid, :normal) end)
    {:ok, base: base, queue: q}
  end

  defp run_opts(base, extra) do
    [
      task: "say hi",
      system: "be terse",
      base_url: base,
      api_key: "test-key",
      limit: [turns: 4, timeout: 10_000]
    ] ++ extra
  end

  test "run/1 OK result carries tokens: tel.total", %{base: base, queue: q} do
    Agent.update(q, fn _ -> [123] end)
    assert {:ok, result} = Nexus.Agent.run(run_opts(base, []))
    assert result.answer == "done"
    assert Map.has_key?(result, :tokens), "ok-result must include :tokens (tel.total)"
    assert result.tokens == 123
  end

  test "interleaved runs of the SAME agent get their OWN token totals (not agent-keyed)", _ do
    {:ok, qa} = Agent.start_link(fn -> [111] end)
    {:ok, qb} = Agent.start_link(fn -> [222] end)
    {porta, pa} = Stub.start(qa)
    {portb, pb} = Stub.start(qb)
    on_exit(fn -> Process.exit(pa, :normal); Process.exit(pb, :normal) end)

    basea = "http://127.0.0.1:#{porta}/v1/chat/completions"
    baseb = "http://127.0.0.1:#{portb}/v1/chat/completions"

    parent = self()
    spawn(fn -> send(parent, {:a, Nexus.Agent.run(run_opts(basea, unit: "iface"))}) end)
    spawn(fn -> send(parent, {:b, Nexus.Agent.run(run_opts(baseb, unit: "iface"))}) end)

    res = for _ <- 1..2, into: %{}, do: (receive do {k, v} -> {k, v} end)

    assert {:ok, %{tokens: 111}} = res.a
    assert {:ok, %{tokens: 222}} = res.b
  end
end
