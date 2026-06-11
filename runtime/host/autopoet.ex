defmodule Workbooks.Autopoet do
  @moduledoc """
  The metacognitive issue backlog — phase 1 of autopoiesis (wb-9ae, see
  docs/AUTOPOIESIS.org). When a tenant agent hits a capability wall ("I need X
  and it does not exist"), it FILES an issue here instead of stalling or faking.
  The autopoet (a central system agent, later phases) works this backlog down,
  implementing each by editing the declarative config layer (toolkits / skills /
  defs / the capability registry) — never native code.

  Issues are ORG FILES (declarative + diffable, like everything the autopoet
  edits) under `WB_DATA/autopoet/issues/<id>.org`. This module is the host
  PRIMITIVE that writes/reads them; it is NOT the autopoet (that is an agent).

  An issue is one of two KINDs:
    * `:capability` — "I need a tool/skill/capability the config layer can
      express." The autopoet can implement these autonomously (a toolkit, a
      def change, a registry entry).
    * `:host`       — "I need a new host primitive the config layer cannot
      express." Human-gated; the autopoet only triages/surfaces these.
  """

  @doc "Directory holding the backlog (system-level, not a tenant repo)."
  def dir, do: Path.join([System.get_env("WB_DATA") || File.cwd!(), "autopoet", "issues"])

  @doc """
  File a metacognitive issue. `attrs`:
    * `:title`    — one line, required
    * `:kind`     — :capability (default) | :host
    * `:tenant`   — who filed it (the agent/app), optional
    * `:need`     — what capability/tool was needed
    * `:tried`    — what the agent tried, and how it failed (evidence)
  Returns `{:ok, id}`. Idempotent on (title, tenant): a duplicate open issue
  with the same title+tenant is NOT re-filed — its `seen` count bumps instead
  (liberal filing + triage: file readily, the backlog dedupes).
  """
  def file_issue(attrs) when is_map(attrs) do
    File.mkdir_p!(dir())
    title = attrs[:title] || attrs["title"] || ""
    if String.trim(to_string(title)) == "" do
      {:error, :no_title}
    else
      case find_open_dup(title, attrs[:tenant] || attrs["tenant"]) do
        {id, path} ->
          bump_seen(path)
          {:ok, id}

        nil ->
          id = new_id()
          File.write!(Path.join(dir(), "#{id}.org"), render(id, attrs))
          {:ok, id}
      end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc "All issues as `%{id, status, kind, title, tenant, seen}` maps, newest first."
  def list(filter \\ :all) do
    case File.ls(dir()) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".org"))
        |> Enum.map(&parse(Path.join(dir(), &1)))
        |> Enum.reject(&is_nil/1)
        |> Enum.filter(fn i -> filter == :all or i.status == filter end)
        |> Enum.sort_by(& &1.id, :desc)

      _ ->
        []
    end
  end

  @doc "Mark an issue claimed/closed. `status` ∈ :open | :doing | :done | :wontfix."
  def set_status(id, status, note \\ nil) do
    path = Path.join(dir(), "#{id}.org")

    with {:ok, body} <- File.read(path) do
      body =
        body
        |> bump_field("STATUS", to_string(status))
        |> maybe_log(status, note)

      File.write!(path, body)
      :ok
    end
  end

  @doc "Reclassify an issue as :host (needs a new host primitive — the human lane)."
  def rekind_host(id) do
    path = Path.join(dir(), "#{id}.org")

    with {:ok, body} <- File.read(path) do
      File.write!(path, bump_field(body, "KIND", "host"))
      :ok
    end
  end

  # ── rendering / parsing (org, so issues are diffable like every other surface) ──

  defp render(id, a) do
    kind = a[:kind] || a["kind"] || :capability

    """
    #+TITLE: #{a[:title] || a["title"]}
    #+ID: #{id}
    #+KIND: #{kind}
    #+STATUS: open
    #+TENANT: #{a[:tenant] || a["tenant"] || "?"}
    #+SEEN: 1

    * need
    #{indent(a[:need] || a["need"] || a[:title] || a["title"])}

    * tried (evidence)
    #{indent(a[:tried] || a["tried"] || "(not given)")}

    * log
    - filed
    """
  end

  defp parse(path) do
    case File.read(path) do
      {:ok, b} ->
        %{
          id: field(b, "ID"),
          status: (field(b, "STATUS") || "open") |> String.to_atom(),
          kind: (field(b, "KIND") || "capability") |> String.to_atom(),
          title: field(b, "TITLE"),
          tenant: field(b, "TENANT"),
          seen: (field(b, "SEEN") || "1") |> String.to_integer()
        }

      _ ->
        nil
    end
  end

  defp find_open_dup(title, tenant) do
    list(:open)
    |> Enum.find_value(fn i ->
      if i.title == to_string(title) and to_string(i.tenant) == to_string(tenant || "?"),
        do: {i.id, Path.join(dir(), "#{i.id}.org")},
        else: nil
    end)
  end

  defp bump_seen(path) do
    with {:ok, b} <- File.read(path) do
      n = (field(b, "SEEN") || "1") |> String.to_integer()
      File.write!(path, bump_field(b, "SEEN", to_string(n + 1)))
    end
  end

  defp field(body, key) do
    case Regex.run(~r/^#\+#{key}:\s*(.+)$/m, body) do
      [_, v] -> String.trim(v)
      _ -> nil
    end
  end

  defp bump_field(body, key, val), do: Regex.replace(~r/^#\+#{key}:.*$/m, body, "#+#{key}: #{val}")

  defp maybe_log(body, _status, nil), do: body
  defp maybe_log(body, status, note), do: body <> "\n- #{status}: #{note}"

  defp indent(text), do: text |> to_string() |> String.split("\n") |> Enum.map_join("\n", &("  " <> &1))

  # Monotonic, sortable, no Date.now/random (those break resume): a zero-padded
  # second-granular timestamp + a unique suffix.
  defp new_id do
    ts = System.system_time(:second)
    "#{ts}-#{System.unique_integer([:positive, :monotonic])}"
  end
end
