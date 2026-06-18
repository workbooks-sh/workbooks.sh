defmodule WorkCore.Log do
  @moduledoc """
  The `work` CLI's structured logging facade — the demo terminal palette
  (`workponents/work-format.css .term`, `sales/salesapp.html`) rendered as real output. Dual mode:
  **ANSI** for humans (24-bit truecolor, the exact palette), **JSON** for agents (`--json` — one
  record per event; the single tool-boundary JSON exception). Every `work` verb emits through here, so
  the whole CLI looks designed and reads the same to a person or a program.

      WorkCore.Log.configure(json: false, color: true)
      WorkCore.Log.prompt("work check sales/")
      WorkCore.Log.ok("12 units · 18 edges", detail: "refs resolve · caps audited")
      WorkCore.Log.warn("2 dangling refs")
  """

  # The exact palette (truecolor RGB) from work-format.css .term.
  @palette %{
    text: {205, 210, 218},
    prompt: {174, 229, 194},
    ok: {127, 214, 160},
    warn: {227, 179, 65},
    err: {235, 120, 120},
    path: {143, 199, 240},
    num: {231, 184, 148},
    dim: {126, 133, 144},
    cmd: {255, 255, 255}
  }

  @doc "Set output mode for this run. Stored in :persistent_term (process-wide, set once at CLI start)."
  def configure(opts) do
    :persistent_term.put({__MODULE__, :mode}, %{
      json: Keyword.get(opts, :json, false),
      color: Keyword.get(opts, :color, color_default?())
    })
  end

  defp mode, do: :persistent_term.get({__MODULE__, :mode}, %{json: false, color: color_default?()})
  defp color_default?, do: System.get_env("NO_COLOR") in [nil, ""]

  # ── token coloring (pure: returns a string) ────────────────────────────────────────────────
  @doc "Color `text` in the role's palette entry (no-op when color is off)."
  def paint(text, role) do
    if mode().color and Map.has_key?(@palette, role) do
      {r, g, b} = @palette[role]
      bold = if role == :cmd, do: "\e[1m", else: ""
      "#{bold}\e[38;2;#{r};#{g};#{b}m#{text}\e[0m"
    else
      to_string(text)
    end
  end

  def cmd(s), do: paint(s, :cmd)
  def path(s), do: paint(s, :path)
  def num(s), do: paint(s, :num)
  def dim(s), do: paint(s, :dim)

  # ── line emitters (print; respect json mode) ───────────────────────────────────────────────
  @doc "A command prompt line: `⟨ work check sales/`."
  def prompt(command), do: line(:prompt, "⟨", command, role: :cmd)

  @doc "A success line: `✓ <msg>`  with optional dim `· <detail>` and `num`-painted counts."
  def ok(msg, opts \\ []), do: line(:ok, "✓", msg, opts)

  @doc "A warning line: `⚠ <msg>`."
  def warn(msg, opts \\ []), do: line(:warn, "⚠", msg, opts)

  @doc "An error line: `✗ <msg>`."
  def error(msg, opts \\ []), do: line(:err, "✗", msg, opts)

  @doc "A neutral step line: `· <msg>` (dim bullet)."
  def step(msg, opts \\ []), do: line(:dim, "·", msg, opts)

  @doc "A plain info line (no glyph)."
  def info(msg), do: line(nil, nil, msg, [])

  defp line(role, glyph, msg, opts) do
    if mode().json do
      rec = %{event: role || :info, msg: to_string(msg)} |> maybe_put(:detail, opts[:detail])
      IO.puts(Jason.encode!(rec))
    else
      g = if glyph, do: paint(glyph, role || :text) <> " ", else: ""
      m = if(opts[:role], do: paint(msg, opts[:role]), else: msg)
      d = if opts[:detail], do: "  " <> paint("· " <> opts[:detail], :dim), else: ""
      IO.puts("#{g}#{m}#{d}")
    end
  end

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)
end
