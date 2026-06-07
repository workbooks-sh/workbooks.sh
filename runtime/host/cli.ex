defmodule Workbooks.CLI do
  @moduledoc """
  The `wb` CLI — folded into the runtime mix project. One binary owns query,
  tangle, bundle, serve, and the variable store, calling straight into the same
  modules the Runtime uses. `call/2` returns output as a string (so an agent can
  run `wb` in-process as a tool); `main/1` prints it.
  """
  alias Workbooks.{OQL, Bundle, Vars, Memory}

  @version "0.1.0"

  def main(argv) do
    {:ok, _} = Application.ensure_all_started(:workbooks)
    IO.puts(call(argv))
  end

  @doc "Run a wb subcommand, returning its output. `tenant` scopes the variable store."
  def call(argv, tenant \\ "dev")

  def call(["query", f], _t), do: f |> File.read!() |> OQL.parse_headlines() |> json()
  def call(["tangle", f], _t), do: f |> File.read!() |> OQL.tangle_plan() |> json()
  def call(["lint", f], _t), do: f |> File.read!() |> OQL.lint() |> json()

  # The variable store + ref (per tenant).
  def call(["var", "set", key, value | rest], t) do
    secret? = "--secret" in rest
    Vars.set(t, key, value, secret?)
    "set #{key}" <> if(secret?, do: " (secret)", else: "")
  end

  def call(["var", "get", key], t) do
    case Vars.get(t, key) do
      {:ok, v} -> v
      {:secret, :redacted, n} -> "<secret: #{n} bytes — ref it with {{secret:#{key}}}, cannot read>"
      :error -> "no such var: #{key}"
    end
  end

  def call(["var", "list"], t) do
    case Vars.list(t) do
      m when map_size(m) == 0 -> "(no variables)"
      m -> Enum.map_join(m, "\n", fn {k, kind} -> "#{k}\t#{kind}" end)
    end
  end

  def call(["var", "ref" | rest], t), do: Vars.ref(t, Enum.join(rest, " "))

  # Agent long-term memory (persists findings across runs).
  def call(["memory", "remember", key | rest], t) do
    Memory.remember(t, key, Enum.join(rest, " "))
    "remembered #{key}"
  end

  def call(["memory", "recall", key], t), do: Memory.recall(t, key) || "no memory: #{key}"

  def call(["memory", "search" | q], t) do
    case Memory.search(t, Enum.join(q, " ")) do
      [] -> "(no matches)"
      hits -> Enum.map_join(hits, "\n", fn %{key: k, content: c} -> "#{k}: #{String.slice(c, 0, 120)}" end)
    end
  end

  def call(["bundle", src, dest], _t) do
    org = File.read!(src)
    parts = %{"source.org" => org, "manifest.json" => Jason.encode!(%{components: OQL.tangle_plan(org), v: 1})}
    File.write!(dest, Bundle.pack(parts))
    "bundled #{map_size(parts)} parts → #{dest}"
  end

  # Observability through the CLI (not a dashboard) — the telemetry + ledger
  # feedback loop over the always-on _steps.jsonl any run writes.
  def call(["telemetry"], _t) do
    runs = Workbooks.Workflow.Telemetry.index()
    if runs == [] do
      "(no runs)"
    else
      header = "SLUG\tSTAGE\tCALLS\tERRORS\tMS"
      rows = Enum.map_join(runs, "\n", fn r ->
        "#{r.slug}\t#{r.stage}\t#{r.tool_calls}\t#{r.errors}\t#{r.total_ms}"
      end)
      "#{header}\n#{rows}"
    end
  end

  def call(["telemetry", slug], _t) do
    case Workbooks.Workflow.Telemetry.summary(wd(slug)) do
      %{error: e} -> e
      s ->
        errs = Enum.map_join(s.errors, "\n", fn e -> "  ! step #{e.step} #{e.tool}: #{e.error}" end)
        "stage=#{s.stage} calls=#{s.tool_calls} errors=#{length(s.errors)} total_ms=#{s.total_ms}" <>
          if(s.errors == [], do: "", else: "\n" <> errs)
    end
  end

  def call(["ledger", slug], _t) do
    case Workbooks.Ledger.verify(wd(slug)) do
      %{error: e} -> e
      v ->
        mark = fn b -> if b, do: "ok", else: "FAIL" end
        "tamper-evident=#{mark.(v.tamper_evident)} attributable=#{mark.(v.attributable)} " <>
          "count=#{v.count} did=#{v.did}"
    end
  end

  # Sign a published artifact with the tenant's did:key (the sharing rail).
  def call(["sign", file | rest], t) do
    out = opt(rest, "--out") || file
    html = File.read!(file)
    signed = Workbooks.Manifest.sign(html, t, [%{"type" => "c2pa.action.published", "actor" => Workbooks.Git.did(t)}])
    File.write!(out, signed)
    "signed #{file} as #{Workbooks.Git.did(t)} → #{out}"
  end

  def call(["verify", file], _t) do
    case Workbooks.Manifest.verify(File.read!(file)) do
      %{error: e} -> e
      v -> "valid=#{v.valid} signature=#{v.signature} asset_integrity=#{v.asset_integrity} issuer=#{v.issuer_did}"
    end
  end

  def call(["version"], _t), do: "wb #{@version}"
  def call(_, _t), do: usage()

  defp opt(args, flag) do
    case Enum.find_index(args, &(&1 == flag)) do
      nil -> nil
      i -> Enum.at(args, i + 1)
    end
  end

  defp wd(slug), do: "/tmp/bb/#{slug}"

  defp json(data), do: Jason.encode!(data, pretty: true)

  defp usage do
    """
    wb — Workbook CLI (#{@version})
      wb query|tangle|lint <file.org>      Org → headlines / build plan / diagnostics
      wb var set <key> <value> [--secret]  set a variable (secrets are ref-only)
      wb var get <key>                     read a variable (secrets redacted)
      wb var list                          list variables
      wb var ref <template>                inject {{var:KEY}} / {{secret:KEY}}
      wb bundle <src.org> <out>            pack a Workbook Bundle
      wb telemetry [<slug>]                runs index, or one run's summary + errors
      wb ledger <slug>                     verify a run's signed ledger (tamper/attribution)
      wb sign <file.html> [--out <f>]      embed a did:key provenance manifest
      wb verify <file.html>                check an artifact's signature + integrity
      wb version
    """
  end
end
