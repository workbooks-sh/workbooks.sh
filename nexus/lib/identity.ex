defmodule Nexus.Identity do
  @moduledoc """
  A nexus's **memorable name** + the local nexus registry.

  Every nexus gets a stable adjective-animal codename (e.g. `adamant-aardvark`) so a human or an agent
  can reference it by something rememberable instead of a port or a URL. The codename is generated
  once and persisted (keyed by port under `~/.workbooks/nexuses/`), so a restart keeps the same name.
  A nexus may also carry a **friendly** name the user/team/org gave it (`WB_NEXUS`) — the legitimate
  reference. Either resolves it.

  The name is a HANDLE, not a credential: it tells the CLI *which* nexus, never grants access — the
  nexus's auth decides that. The registry (`~/.work/nexuses.html`, where the CLI reads its config)
  lists `{name, friendly, url}` for the nexuses on this machine; cloud/account nexuses layer on later.
  """

  @adjectives ~w(adamant amber azure bold brave bright calm clever cobalt coral crimson dapper eager
                 fabled gentle golden hardy jolly keen lively lucid mellow noble plucky quiet rapid
                 regal scarlet shy sly spry stark steady stoic sunny swift teal vivid witty zesty)

  @animals ~w(aardvark badger bison cobra crane dingo eagle falcon ferret gecko heron ibex jackal
              koala lemur lynx marten mongoose narwhal ocelot osprey otter panda quokka raven seal
              stork tapir thrush urchin viper walrus wombat yak zebra)

  @doc "This nexus's stable codename (generated + persisted once, keyed by `port`)."
  def codename(port) do
    file = Path.join(names_dir(), to_string(port))

    case File.read(file) do
      {:ok, name} ->
        String.trim(name)

      _ ->
        name = generate()
        File.mkdir_p!(names_dir())
        File.write!(file, name)
        name
    end
  end

  @doc "Record `{name, friendly, url}` in the CLI-readable nexus registry (upsert by url)."
  def register(name, friendly, url) do
    path = registry_path()
    File.mkdir_p!(Path.dirname(path))
    line = ~s(<nexus name="#{name}" friendly="#{friendly}" url="#{url}">)

    existing =
      case File.read(path) do
        {:ok, c} -> c |> lines() |> Enum.reject(&String.contains?(&1, ~s(url="#{url}")))
        _ -> []
      end

    body = "<work-nexuses>\n" <> Enum.join(existing ++ [line], "\n") <> "\n</work-nexuses>\n"
    File.write!(path, body)
  end

  @doc "The registered nexuses on this machine: `[%{name, friendly, url}]`."
  def list do
    case File.read(registry_path()) do
      {:ok, c} ->
        c
        |> lines()
        |> Enum.map(fn l ->
          %{name: attr(l, "name"), friendly: attr(l, "friendly"), url: attr(l, "url")}
        end)
        |> Enum.reject(&(&1.url == ""))

      _ ->
        []
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────────────────────────

  defp generate do
    base = "#{Enum.random(@adjectives)}-#{Enum.random(@animals)}"
    taken = list() |> Enum.map(& &1.name) |> MapSet.new()
    # add a small number only if the pretty name is already taken on this machine
    if MapSet.member?(taken, base), do: "#{base}-#{:rand.uniform(99)}", else: base
  end

  defp lines(content) do
    content
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&String.starts_with?(&1, "<nexus "))
  end

  defp attr(line, name) do
    case Regex.run(~r/#{name}="([^"]*)"/, line) do
      [_, v] -> v
      _ -> ""
    end
  end

  defp names_dir, do: Path.join(Nexus.Workbooks.home(), "nexuses")

  # The CLI keeps its config under ~/.work; the registry lives there so `work` reads it natively.
  defp registry_path, do: Path.join([System.get_env("HOME") || ".", ".work", "nexuses.html"])
end
