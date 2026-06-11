defmodule Workbooks.Groundskeeper.ElevenLabs do
  @moduledoc """
  ElevenLabs Agents client — provisions the groundskeeper voice agent over the
  Agents-platform API and runs text SIMULATIONS of conversations (the self-test
  path: validate persona + tool-calling end-to-end with no human on the call).

  The key lives host-side (`ELEVENLABS_API_KEY`), same secrets-by-reference
  rule as `Workbooks.Llm`. The agent is THIN by design: persona prompt + five
  webhook tools pointing at the /gk bridge; all state stays in the runtime.

  Persona source of truth: <gk_home>/agent/groundskeeper.org (the def file,
  read under its `** System prompt` heading) — provisioning is a dev-box op
  where the repo exists.
  """
  require Logger

  @base "https://api.elevenlabs.io"

  # ── provisioning ────────────────────────────────────────────────────────────

  @doc """
  Create the agent (or update when WB_GK_AGENT_ID is set) wired to the bridge
  at `base_url` (e.g. "https://runtime.example.com"). Returns {:ok, agent_id}.
  """
  def upsert_agent(base_url) do
    body = %{
      name: "groundskeeper",
      conversation_config: %{
        agent: %{
          # The app computes a contextual opener per call (time of day +
          # fresh results) and passes it as a dynamic variable.
          first_message: "{{greeting}}",
          prompt: %{
            prompt: persona!(),
            tools: tools(base_url)
          }
        },
        # David — deep smooth Scottish. English agents require turbo/flash v2
        # (v3 expressive is plan-gated, multilingual rejected).
        tts: %{voice_id: System.get_env("WB_GK_VOICE_ID", "1N4VgTBW1ZGBv5IHWRAf"), model_id: "eleven_turbo_v2"},
        # Fill-the-silence: when the founder goes quiet this long, the agent
        # takes the turn (persona law 3 says how).
        turn: %{turn_timeout: 10}
      }
    }

    case System.get_env("WB_GK_AGENT_ID") do
      nil ->
        with {:ok, %{"agent_id" => id}} <- request(:post, "/v1/convai/agents/create", body),
             do: {:ok, id}

      id ->
        with {:ok, _} <- request(:patch, "/v1/convai/agents/#{id}", body), do: {:ok, id}
    end
  end

  def get_agent(id), do: request(:get, "/v1/convai/agents/#{id}")
  def list_agents, do: request(:get, "/v1/convai/agents")

  @doc """
  Mint a short-lived signed conversation URL for the (private) agent — what the
  workbook app uses to start a browser voice session without ever seeing the
  API key. Agent id from WB_GK_AGENT_ID.
  """
  def signed_url do
    id = System.get_env("WB_GK_AGENT_ID") || raise "WB_GK_AGENT_ID not set"

    with {:ok, %{"signed_url" => url}} <-
           request(:get, "/v1/convai/conversation/get-signed-url?agent_id=#{id}"),
         do: {:ok, url}
  end

  @doc """
  Run a server-side TEXT simulation of a conversation with the agent — the
  self-demo: a simulated founder talks; the agent (with its real prompt and
  tool configuration) responds and calls tools. Returns the simulated
  transcript + analysis. `user_prompt` describes the simulated founder.
  """
  def simulate(agent_id, user_prompt, opts \\ []) do
    body = %{
      simulation_specification: %{
        simulated_user_config: %{
          prompt: %{prompt: user_prompt}
        }
      },
      new_turns_limit: opts[:turns] || 6
    }

    request(:post, "/v1/convai/agents/#{agent_id}/simulate-conversation", body)
  end

  # ── the five tools (mirror Workbooks.Groundskeeper exactly) ─────────────────

  defp tools(base_url) do
    secret = System.get_env("WB_GK_SECRET") || raise "WB_GK_SECRET required to provision"

    webhook = fn name, description, properties, required ->
      %{
        type: "webhook",
        name: name,
        description: description,
        api_schema: %{
          url: "#{base_url}/gk/tool/#{name}",
          method: "POST",
          request_headers: %{"x-gk-secret" => secret},
          request_body_schema: %{
            type: "object",
            properties: properties,
            required: required
          }
        }
      }
    end

    [
      webhook.(
        "repo_state",
        "The ONLY source of truth about the repository. Call before ANY statement about project state. query: summary | ready | issues | log.",
        %{query: %{type: "string", description: "summary | ready | issues | log"}},
        []
      ),
      webhook.(
        "capture",
        "Silently save a distilled thought from the conversation (an idea, decision, question, or note). Do not read it back; just keep talking.",
        %{
          text: %{type: "string", description: "the distilled thought, one to three sentences"},
          kind: %{type: "string", description: "idea | decision | question | note"}
        },
        ["text"]
      ),
      webhook.(
        "file_issue",
        "File a tracked issue in the project ledger when the founder commits to a piece of work or names a bug.",
        %{
          title: %{type: "string", description: "one-line issue title"},
          description: %{type: "string", description: "context: why, where, what done looks like"}
        },
        ["title"]
      ),
      webhook.(
        "dispatch",
        "Send a background research/investigation goal to the runtime. A separate author writes and runs the workflow; results arrive later via tasks. Use for anything that needs real investigation.",
        %{goal: %{type: "string", description: "the investigation goal, concrete and self-contained"}},
        ["goal"]
      ),
      webhook.(
        "tasks",
        "List dispatched background tasks and any fresh completions. Call when asked what's running, and at the start of a conversation.",
        %{},
        []
      )
    ]
  end

  # ── persona ─────────────────────────────────────────────────────────────────

  # The def file's `** System prompt` section (the AgentDef convention — the
  # prompt MUST live under that heading or the agent runs empty).
  defp persona! do
    path = Path.join([Workbooks.Groundskeeper.home(), "agent", "groundskeeper.org"])
    org = File.read!(path)

    case Regex.run(~r/^\*\* System prompt\n(.*?)(?=^\* |\z)/ms, org) do
      [_, prompt] -> String.trim(prompt)
      _ -> raise "no `** System prompt` heading in #{path}"
    end
  end

  # ── http ────────────────────────────────────────────────────────────────────

  defp request(method, path, body \\ nil) do
    :inets.start()
    :ssl.start()
    key = System.get_env("ELEVENLABS_API_KEY") || raise "ELEVENLABS_API_KEY not set"
    url = ~c"#{@base}#{path}"
    headers = [{~c"xi-api-key", ~c"#{key}"}]

    req =
      if body,
        do: {url, headers, ~c"application/json", Jason.encode!(body)},
        else: {url, headers}

    case :httpc.request(method, req, [timeout: 120_000], body_format: :binary) do
      {:ok, {{_, status, _}, _, resp}} when status in 200..299 ->
        {:ok, Jason.decode!(resp)}

      {:ok, {{_, status, _}, _, resp}} ->
        Logger.warning("elevenlabs #{method} #{path} -> #{status}: #{String.slice(resp, 0, 500)}")
        {:error, {status, resp}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
