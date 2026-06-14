defmodule Workbooks.ToolkitDescriptorTest do
  @moduledoc """
  Pins parse_descriptor/1 — the pure decode of a toolkit manifest's EXEC-shape
  contract (how a toolkit declares it builds + runs). A regression here silently
  misroutes the build (e.g. a `crate:` source falling through to :unknown → the
  whole autobuild lane breaks) without any eval/injection test noticing.
  Deterministic: pure string → map, no kernel/LLM.
  """
  use ExUnit.Case, async: true

  alias Workbooks.Toolkits

  test "a full command-toolkit descriptor decodes every field" do
    body = """
    #+TITLE: Huniq
    #+EXEC: command
    #+TRUST: first-party
    #+BUILD_SRC: crate:huniq
    #+BUILD_LANG: rust
    #+CAPS: stdio fs
    #+CLI_BIN: huniq
    #+ARG_MODE: stdin1
    """

    d = Toolkits.parse_descriptor(body)
    assert d.exec == "command"
    assert d.trust == "first-party"
    assert d.build_src == {:crate, "huniq"}
    assert d.build_lang == "rust"
    assert d.caps == ["stdio", "fs"]
    assert d.cli_bin == "huniq"
    assert d.arg_mode == :stdin1
  end

  test "defaults: trust → first-party, arg_mode → :argv, caps → [] when absent" do
    d = Toolkits.parse_descriptor("#+EXEC: component\n")
    assert d.exec == "component"
    assert d.trust == "first-party"
    assert d.arg_mode == :argv
    assert d.caps == []
    assert d.build_src == nil
  end

  test "every BUILD_SRC scheme decodes to its tagged tuple (and an unknown is tagged, not dropped)" do
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
      d = Toolkits.parse_descriptor("#+BUILD_SRC: #{spec}\n")
      assert d.build_src == expected, "BUILD_SRC #{spec} → #{inspect(d.build_src)}"
    end
  end
end
