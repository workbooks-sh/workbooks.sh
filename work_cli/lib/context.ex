defmodule WorkCLI.Context do
  @moduledoc """
  The CLI's **context** — the kubectl-style mechanism that makes `work` feel like one tool over many
  backends. A context names a target: which nexus (local or remote URL), which org/workspace, and the
  active identity. Stored as `~/.work/context.html` — a `<work-context active="…">` element with one
  `<work-target>` child per target (HTML, no JSON, on-canon). Every client verb (`deploy verify`,
  `dev` hot-swap, future `run`/`kit`) resolves the active target through here, with `--nexus` /
  `WB_RUNTIME_URL` as per-invocation overrides.
  """


  @doc "Load the context → `%{active: name, targets: %{name => %{nexus, org, workspace}}}`."
  def load do
    case File.read(path()) do
      {:ok, html} -> parse(html)
      _ -> %{active: "local", targets: %{"local" => %{"nexus" => "http://localhost:4000"}}}
    end
  end

  @doc "The active target's attributes (`%{\"nexus\" => …}`), or the local default."
  def active_target do
    ctx = load()
    ctx.targets[ctx.active] || %{"nexus" => "http://localhost:4000"}
  end

  @doc "The active nexus URL (override: `WB_RUNTIME_URL`)."
  def nexus_url do
    case System.get_env("WB_RUNTIME_URL") do
      v when v in [nil, ""] -> active_target()["nexus"] || "http://localhost:4000"
      v -> v
    end
  end

  @doc "Upsert a target (and make it active). `attrs` keys: \"nexus\" \"org\" \"workspace\"."
  def set(name, attrs) do
    ctx = load()
    target = Map.merge(ctx.targets[name] || %{}, Enum.reject(attrs, fn {_, v} -> v in [nil, ""] end) |> Map.new())
    save(%{ctx | active: name, targets: Map.put(ctx.targets, name, target)})
  end

  @doc "Switch the active target. `{:error, :unknown}` if it isn't defined."
  def use(name) do
    ctx = load()
    if Map.has_key?(ctx.targets, name), do: (save(%{ctx | active: name}); :ok), else: {:error, :unknown}
  end

  def save(ctx) do
    File.mkdir_p!(dir())
    File.write!(path(), render(ctx))
    :ok
  end

  # ── HTML <work-context> serialization ──────────────────────────────────────────────────────
  defp render(ctx) do
    targets =
      ctx.targets
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join("\n", fn {name, a} ->
        attrs = for k <- ~w(nexus org workspace), a[k] not in [nil, ""], into: "", do: ~s( #{k}="#{esc(a[k])}")
        ~s(  <work-target name="#{esc(name)}"#{attrs}></work-target>)
      end)

    ~s(<work-context active="#{esc(ctx.active)}">\n#{targets}\n</work-context>\n)
  end

  @doc false
  def parse(html) do
    active =
      case Regex.run(~r/<work-context\b[^>]*\bactive="([^"]*)"/, html) do
        [_, a] -> a
        _ -> "local"
      end

    targets =
      Regex.scan(~r/<work-target\b([^>]*)>/, html)
      |> Map.new(fn [_, attrs] ->
        a = Regex.scan(~r/([a-z]+)="([^"]*)"/, attrs) |> Map.new(fn [_, k, v] -> {k, v} end)
        {a["name"] || "default", Map.delete(a, "name")}
      end)

    %{active: active, targets: (if targets == %{}, do: %{"local" => %{"nexus" => "http://localhost:4000"}}, else: targets)}
  end

  defp path, do: Application.get_env(:work_cli, :context_file) || Path.expand("~/.work/context.html")
  defp dir, do: Path.dirname(path())
  defp esc(s), do: s |> to_string() |> String.replace("&", "&amp;") |> String.replace("\"", "&quot;") |> String.replace("<", "&lt;")
end
