defmodule Workbooks.ToolkitDescriptorTest do
  @moduledoc """
  Pins parse_descriptor/1 — the pure decode of a `<work-ref rel="kit">` manifest's
  EXEC-shape contract (how a toolkit declares it builds + runs). A regression here
  silently misroutes the build (e.g. a `crate:` source falling through to :unknown
  → the whole autobuild lane breaks) without any eval/injection test noticing.
  Deterministic: pure HTML string → map, no kernel/LLM.
  """
  use ExUnit.Case, async: true

  alias Workbooks.WorkKits

  test "a full command-toolkit descriptor decodes every field" do
    body = """
    <work-ref rel="kit" name="huniq" cli="huniq" exec="command" trust="first-party"
      build-src="crate:huniq" build-lang="rust" caps="stdio fs" arg-mode="stdin1"/>
    <work-doc title="Huniq"></work-doc>
    """

    d = WorkKits.parse_descriptor(body)
    assert d.exec == "command"
    assert d.trust == "first-party"
    assert d.build_src == {:crate, "huniq"}
    assert d.build_lang == "rust"
    assert d.caps == ["stdio", "fs"]
    assert d.cli_bin == "huniq"
    assert d.arg_mode == :stdin1
  end

  test "defaults: trust → first-party, arg_mode → :argv, caps → [] when absent" do
    d = WorkKits.parse_descriptor(~s(<work-ref rel="kit" name="x" exec="component"/>))
    assert d.exec == "component"
    assert d.trust == "first-party"
    assert d.arg_mode == :argv
    assert d.caps == []
    assert d.build_src == nil
  end

  test "every build-src scheme decodes to its tagged tuple (and an unknown is tagged, not dropped)" do
    schemes = [
      {"crate:serde", {:crate, "serde"}},
      {"git+https://x/y.git", {:git, "https://x/y.git"}},
      {"path:./local", {:path, "./local"}},
      {"wasm:https://x/m.wasm", {:wasm, "https://x/m.wasm"}},
      {"archive:https://x/a.tgz", {:archive, "https://x/a.tgz"}},
      {"gobuild:github.com/x/y", {:gobuild, "github.com/x/y"}},
      {"script:build.sh", {:script, "build.sh"}},
      {"zigbuild:src/main.zig", {:zigbuild, "src/main.zig"}},
      {"mystery:thing", {:unknown, "mystery:thing"}}
    ]

    for {spec, expected} <- schemes do
      d = WorkKits.parse_descriptor(~s(<work-ref rel="kit" name="x" build-src="#{spec}"/>))
      assert d.build_src == expected, "build-src #{spec} → #{inspect(d.build_src)}"
    end
  end
end
