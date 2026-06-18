defmodule Nexus.ComputerUse do
  @moduledoc """
  An experiment: **multimodal computer-use over the in-wasm browser.** A vision model (Gemma 3 12B by
  default) looks at a screenshot of the page (rendered by Blitz in wasmtime) plus the actionable
  elements (`Nexus.Browse.Session`), picks ONE action, and we execute it via Tier 1 — then loop. No
  Chromium: the page is rendered + operated entirely in-sandbox; only the model call is remote.

      Nexus.ComputerUse.run("Find the top story on Hacker News and report its title.",
                            "https://news.ycombinator.com/")
  """

  @model "google/gemma-3-12b-it"
  @max_steps 8

  def run(task, start_url, opts \\ []) do
    model = Keyword.get(opts, :model, @model)
    max_steps = Keyword.get(opts, :max_steps, @max_steps)
    {:ok, session} = Nexus.Browse.Session.navigate(start_url)
    loop(task, session, model, max_steps, [])
  end

  defp loop(_task, _s, _model, 0, log), do: {:max_steps, Enum.reverse(log)}

  defp loop(task, session, model, steps_left, log) do
    png = screenshot(session.url)
    prompt = build_prompt(task, session)

    case ask(model, prompt, png) do
      {:ok, raw} ->
        action = parse_action(raw)
        log = [%{step: length(log) + 1, url: session.url, action: action, raw: raw} | log]

        case execute(action, session) do
          {:done, answer} -> {:ok, answer, Enum.reverse(log)}
          {:ok, session2} -> loop(task, session2, model, steps_left - 1, log)
          {:error, _} -> loop(task, session, model, steps_left - 1, log)
        end

      {:error, reason} ->
        {:error, reason, Enum.reverse(log)}
    end
  end

  # ── the prompt the model sees ──────────────────────────────────────────────
  defp build_prompt(task, s) do
    links = s.links |> Enum.take(25) |> Enum.with_index(1) |> Enum.map_join("\n", fn {l, i} -> "  #{i}. #{String.slice(l.text, 0, 70)}" end)
    forms = s.forms |> Enum.with_index(1) |> Enum.map_join("\n", fn {f, i} -> "  form #{i}: #{f.method} fields=#{Enum.map_join(f.fields, ",", & &1.name)}" end)

    """
    You are operating a web browser to accomplish a task. You see a screenshot of the current page
    and a list of actionable elements. Decide the SINGLE next action.

    TASK: #{task}

    CURRENT URL: #{s.url}

    PAGE TEXT (excerpt):
    #{String.slice(s.text, 0, 1500)}

    LINKS (click by number):
    #{links}

    FORMS:
    #{if forms == "", do: "  (none)", else: forms}

    If the PAGE TEXT or screenshot already lets you answer the task, reply `DONE: <answer>` NOW —
    do not keep clicking. Otherwise reply with EXACTLY ONE action, nothing else:
      CLICK <n>
      FILL <form-field-name>=<value>
      SUBMIT <form-number>
      NAVIGATE <url>
      DONE: <your final answer to the task>
    """
  end

  # ── the multimodal model call ──────────────────────────────────────────────
  defp ask(model, text, png) do
    :inets.start()
    :ssl.start()
    key = System.get_env("OPENROUTER_API_KEY")

    content =
      [%{type: "text", text: text}] ++
        if(png, do: [%{type: "image_url", image_url: %{url: "data:image/png;base64," <> Base.encode64(png)}}], else: [])

    body = Jason.encode!(%{model: model, messages: [%{role: "user", content: content}]})
    req = {~c"https://openrouter.ai/api/v1/chat/completions", [{~c"authorization", ~c"Bearer #{key}"}], ~c"application/json", body}

    case :httpc.request(:post, req, [timeout: 90_000], body_format: :binary) do
      {:ok, {{_, 200, _}, _, resp}} ->
        case Jason.decode(resp) do
          {:ok, %{"choices" => [%{"message" => %{"content" => c}} | _]}} -> {:ok, c}
          _ -> {:error, :bad_response}
        end

      {:ok, {{_, s, _}, _, r}} ->
        {:error, {:http, s, String.slice(to_string(r), 0, 150)}}

      e ->
        {:error, e}
    end
  end

  defp screenshot(url) do
    case Nexus.Browse.screenshot(url, height: 1400) do
      {:ok, png} -> png
      _ -> nil
    end
  end

  # ── parse + execute ────────────────────────────────────────────────────────
  defp parse_action(raw) do
    # DONE wins wherever it appears — the model often answers AND suggests a click; if it has the
    # answer, finish.
    if Regex.match?(~r/DONE:/i, raw) do
      {:done, raw |> String.replace(~r/.*?DONE:\s*/is, "") |> String.split("\n") |> List.first() |> String.trim()}
    else
      parse_first_action(raw)
    end
  end

  defp parse_first_action(raw) do
    line = raw |> String.split("\n", trim: true) |> List.first() |> to_string() |> String.trim()

    cond do
      Regex.match?(~r/^DONE:/i, line) -> {:done, String.replace(line, ~r/^DONE:\s*/i, "")}
      Regex.match?(~r/^CLICK\s+/i, line) -> {:click, line |> String.replace(~r/^CLICK\s+/i, "") |> String.trim()}
      Regex.match?(~r/^SUBMIT\s+/i, line) -> {:submit, line |> String.replace(~r/^SUBMIT\s+/i, "") |> String.trim()}
      Regex.match?(~r/^NAVIGATE\s+/i, line) -> {:navigate, line |> String.replace(~r/^NAVIGATE\s+/i, "") |> String.trim()}
      Regex.match?(~r/^FILL\s+/i, line) ->
        case String.split(String.replace(line, ~r/^FILL\s+/i, ""), "=", parts: 2) do
          [f, v] -> {:fill, String.trim(f), String.trim(v)}
          _ -> {:unknown, line}
        end

      true -> {:unknown, line}
    end
  end

  defp execute({:done, answer}, _s), do: {:done, answer}
  defp execute({:click, target}, _s), do: Nexus.Browse.Session.click(target)
  defp execute({:navigate, url}, _s), do: Nexus.Browse.Session.navigate(url)
  defp execute({:fill, f, v}, s), do: Nexus.Browse.Session.fill(f, v) && {:ok, s}
  defp execute({:submit, n}, _s) do
    idx = case Integer.parse(n), do: ({i, _} -> i; _ -> 1)
    Nexus.Browse.Session.submit(idx)
  end

  defp execute({:unknown, _}, s), do: {:ok, s}
end
