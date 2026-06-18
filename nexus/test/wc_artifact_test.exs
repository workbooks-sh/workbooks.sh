defmodule Nexus.ArtifactTest do
  use ExUnit.Case, async: true
  alias Nexus.{Artifact, Wit, Graph, Overlay}

  @tmp Path.join(System.tmp_dir!(), "wc_artifact_test")

  setup do
    File.rm_rf!(@tmp)
    File.mkdir_p!(@tmp)
    on_exit(fn -> File.rm_rf!(@tmp) end)
    :ok
  end

  # a real compiled component: a trivial core module exporting run(), lifted to a
  # component against a declared world.
  defp build_component do
    wat = Path.join(@tmp, "core.wat")
    core = Path.join(@tmp, "core.wasm")
    File.write!(wat, "(module (func (export \"run\") (result i32) i32.const 42))")
    {_, 0} = System.cmd("wasm-tools", ["parse", wat, "-o", core])
    world = "package work:demo;\nworld demo {\n  export run: func() -> s32;\n}\n"
    {:ok, comp} = Wit.componentize(core, world, "demo")
    {comp, world}
  end

  test "reads a compiled component's real WIT back and parses its interface" do
    {comp, _world} = build_component()
    {:ok, facet} = Artifact.facet(comp)
    assert "run" in facet.exports
    assert facet.wit =~ "export run:"
  end

  test "annotate_node populates the artifact facet" do
    {comp, _world} = build_component()
    node = %{id: "demo", facets: %{source: %{}, interface: nil, artifact: nil, data: %{}}}
    node = Artifact.annotate_node(node, comp)
    assert node.facets.artifact.exports == ["run"]
  end

  test "diff confirms declared matches the compiled binary" do
    {comp, world} = build_component()
    {:ok, actual} = Artifact.read_wit(comp)
    d = Artifact.diff(world, actual)
    assert d.ok?
    assert d.missing_exports == []
    assert d.extra_exports == []
  end

  test "diff flags drift — a declared export absent from the binary" do
    {comp, _world} = build_component()
    {:ok, actual} = Artifact.read_wit(comp)
    declared = "package work:demo;\nworld demo {\n  export run: func() -> s32;\n  export ghost: func() -> s32;\n}\n"
    d = Artifact.diff(declared, actual)
    refute d.ok?
    assert "ghost" in d.missing_exports
  end

  test "artifact overlay joins onto the graph node's facets.artifact" do
    File.write!(Path.join(@tmp, "svc.work"), "# Svc\n\n```elixir\nserver :svc do\n  def go, do: :ok\nend\n```\n")
    g = Graph.build_dir(@tmp)
    assert g.nodes["svc"].facets.artifact == nil

    facet = %{exports: ["go"], imports: [], wit: "world svc { export go: func() -> string; }", drift: %{ok?: true}}
    ov = Overlay.put_artifact(Overlay.new(), "svc", facet)
    lensed = Graph.with_overlay(g, ov)

    assert lensed.nodes["svc"].facets.artifact.exports == ["go"]
    assert lensed.nodes["svc"].facets.artifact.drift.ok?
    # pure graph untouched
    assert g.nodes["svc"].facets.artifact == nil
  end
end
