defmodule Workbooks.AgentBundleLoopTest do
  @moduledoc """
  Pins the AGENT's in-run workbook edit loop — unbundle → edit native source →
  re-bundle — driven entirely through the agent's `work` tool surface (the bash
  membrane), NOT a native unzip binary and NOT a second wasm zip lane.

  Per the MAP.sandbox decision: bundle/unbundle is pure byte manipulation the host
  already does in `Workbooks.Bundle` (Elixir `:zip` + base64 embed), so the guest
  emits the INTENT (`work unbundle …` / `work bundle …` over its bash surface) and the
  host performs the IO — the same brokered-IO precedent as js_dock. One Bundle home,
  no native exec, no second zip implementation to drift.

  This drives the loop through `Agent.__exec_one_for_test__` (the exact path a live
  exec agent takes: `OptionParser.split` → `Workbooks.CLI.call`), so it pins the
  whole brokered round-trip AND the exec gate. Hermetic — no network, no LLM, no
  GenServer (the tree carries its own index.html so OQL.render is never invoked).
  """
  use ExUnit.Case, async: true

  alias Workbooks.{Agent, Bundle}

  defp wb(args, exec),
    do: Agent.__exec_one_for_test__(%{name: "work", args: %{"args" => args}}, %{tenant: nil, exec: exec})

  setup do
    base = Path.join(System.tmp_dir!(), "agent_bundle_loop_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, base: base}
  end

  test "the edit loop runs over the agent's work tool: unbundle → edit → re-bundle", %{base: base} do
    # A starting self-contained workbook .html (page + embedded source tree). Built
    # via the same Bundle primitive the host serves, so the fixture is honest.
    src_tree = %{
      "index.html" => "<!doctype html><html><body><h1>before</h1></body></html>",
      "src/app.svelte" => "<h1>{count}</h1>\n",
      "data/blob.bin" => :crypto.strong_rand_bytes(2048)
    }

    html0 =
      Bundle.embed(src_tree["index.html"], Bundle.pack(src_tree))

    workbook = Path.join(base, "workbook.html")
    workdir = Path.join(base, "work")
    rebuilt = Path.join(base, "rebuilt.html")
    File.mkdir_p!(base)
    File.write!(workbook, html0)

    # 1. UNBUNDLE — the host extracts the embedded zip to a working tree (intent in,
    #    host runs :zip; the agent never shells out to unzip).
    {out_un, _st} = wb("unbundle #{workbook} #{workdir}", true)
    assert out_un =~ "unbundled 3 files"

    for {name, content} <- src_tree do
      assert File.read!(Path.join(workdir, name)) == content, "unbundle mismatch: #{name}"
    end

    # 2. EDIT native source directly on the working tree (the agent's file tools).
    File.write!(Path.join(workdir, "src/app.svelte"), "<h1>{count} edited</h1>\n")
    File.write!(Path.join(workdir, "index.html"), "<!doctype html><html><body><h1>after</h1></body></html>")

    # 3. RE-BUNDLE — the host re-packs the edited tree into one self-contained .html.
    {out_bd, _st} = wb("bundle #{workdir} #{rebuilt}", true)
    assert out_bd =~ "bundled 3 files"

    rebuilt_html = File.read!(rebuilt)
    # the page reflects the edit, and the embedded payload carries the edited source.
    assert rebuilt_html =~ "<h1>after</h1>"
    parts = Bundle.unpack(Bundle.extract(rebuilt_html))
    assert parts["src/app.svelte"] =~ "edited"
    assert parts["data/blob.bin"] == src_tree["data/blob.bin"]
  end

  test "BOTH edit-loop verbs are exec-gated — a sandboxed (exec-denied) agent is refused", %{base: base} do
    # unbundle writes a whole tree to a caller-supplied dir (raw File IO, not
    # tenant-scoped); bundle reads a caller-supplied tree. Reaching either from an
    # exec-denied agent would let it read/write arbitrary host paths, so both are
    # gated like deploy/git. Refusal must short-circuit BEFORE any File.read!.
    leak = Path.join(base, "leak")

    {out_un, _} = wb("unbundle /etc/hosts #{leak}", false)
    assert out_un =~ "not permitted"

    {out_bd, _} = wb("bundle /etc #{Path.join(base, "out.html")}", false)
    assert out_bd =~ "not permitted"

    # the gate held: nothing was written / read out.
    refute File.exists?(leak)
    refute File.exists?(Path.join(base, "out.html"))
  end
end
